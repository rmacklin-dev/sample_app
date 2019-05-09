require "concurrent/utility/processor_counter"
require "drb"
require "drb/unix" unless Gem.win_platform?
require "active_support/core_ext/module/attribute_accessors"

module ActiveSupport
  module Testing
    class Parallelization # :nodoc:
      class Server
        include DRb::DRbUndumped

        def initialize
          @queue = Queue.new
        end

        def record(reporter, result)
          raise DRb::DRbConnError if result.is_a?(DRb::DRbUnknown)

          reporter.synchronize do
            reporter.record(result)
          end
        end

        def <<(o)
          o[2] = DRbObject.new(o[2]) if o
          @queue << o
        end

        def pop; @queue.pop; end
      end

      @@after_fork_hooks = []

      def self.after_fork_hook(&blk)
        @@after_fork_hooks << blk
      end

      cattr_reader :after_fork_hooks

      @@run_cleanup_hooks = []

      def self.run_cleanup_hook(&blk)
        @@run_cleanup_hooks << blk
      end

      cattr_reader :run_cleanup_hooks

      def initialize(queue_size)
        @queue_size = queue_size
        @queue      = Server.new
        @pool       = []

        @url = DRb.start_service("drbunix:", @queue).uri
      end

      def after_fork(worker)
        self.class.after_fork_hooks.each do |cb|
          cb.call(worker)
        end
      end

      def run_cleanup(worker)
        self.class.run_cleanup_hooks.each do |cb|
          cb.call(worker)
        end
      end

      def start
        @pool = @queue_size.times.map do |worker|
          fork do
            DRb.stop_service

            begin
              after_fork(worker)
            rescue => setup_exception; end

            queue = DRbObject.new_with_uri(@url)

            while job = queue.pop
              klass    = job[0]
              method   = job[1]
              reporter = job[2]
              result = klass.with_info_handler reporter do
                Minitest.run_one_method(klass, method)
              end

              add_setup_exception(result, setup_exception) if setup_exception

              begin
                queue.record(reporter, result)
              rescue DRb::DRbConnError
                result.failures.each do |failure|
                  failure.exception = DRb::DRbRemoteError.new(failure.exception)
                end
                queue.record(reporter, result)
              end
            end
          ensure
            run_cleanup(worker)
          end
        end
      end

      def <<(work)
        @queue << work
      end

      def shutdown
        @queue_size.times { @queue << nil }
        @pool.each { |pid| Process.waitpid pid }
      end

      private
        def add_setup_exception(result, setup_exception)
          result.failures.prepend Minitest::UnexpectedError.new(setup_exception)
        end
    end
  end
end

module ActiveRecord
  module TestDatabases # :nodoc:
    ActiveSupport::Testing::Parallelization.after_fork_hook do |i|
      create_and_load_schema(i, env_name: Rails.env)
    end

    ActiveSupport::Testing::Parallelization.run_cleanup_hook do
      drop(env_name: Rails.env)
    end

    def self.create_and_load_schema(i, env_name:)
      old, ENV["VERBOSE"] = ENV["VERBOSE"], "false"

      ActiveRecord::Base.configurations.configs_for(env_name: env_name).each do |db_config|
        db_config.config["database"] += "-#{i}"
        ActiveRecord::Tasks::DatabaseTasks.create(db_config.config)
        ActiveRecord::Tasks::DatabaseTasks.load_schema(db_config.config, ActiveRecord::Base.schema_format, nil, env_name, db_config.spec_name)
      end
    ensure
      ActiveRecord::Base.establish_connection(Rails.env.to_sym)
      ENV["VERBOSE"] = old
    end

    def self.drop(env_name:)
      old, ENV["VERBOSE"] = ENV["VERBOSE"], "false"

      ActiveRecord::Base.configurations.configs_for(env_name: env_name).each do |db_config|
        ActiveRecord::Tasks::DatabaseTasks.drop(db_config.config)
      end
    ensure
      ENV["VERBOSE"] = old
    end
  end
end

module ActiveRecord
  module TestFixturesExtension
    extend ActiveSupport::Concern

    included do
      class_attribute :lock_threads, default: true
    end
  end

  module TestFixtures
    def setup_fixtures(config = ActiveRecord::Base)
      if pre_loaded_fixtures && !use_transactional_tests
        raise RuntimeError, "pre_loaded_fixtures requires use_transactional_tests"
      end

      @fixture_cache = {}
      @fixture_connections = []
      @@already_loaded_fixtures ||= {}
      @connection_subscriber = nil

      # Load fixtures once and begin transaction.
      if run_in_transaction?
        if @@already_loaded_fixtures[self.class]
          @loaded_fixtures = @@already_loaded_fixtures[self.class]
        else
          @loaded_fixtures = load_fixtures(config)
          @@already_loaded_fixtures[self.class] = @loaded_fixtures
        end

        # Begin transactions for connections already established
        @fixture_connections = enlist_fixture_connections
        @fixture_connections.each do |connection|
          connection.begin_transaction joinable: false
          connection.pool.lock_thread = true if lock_threads
        end

        # When connections are established in the future, begin a transaction too
        @connection_subscriber = ActiveSupport::Notifications.subscribe("!connection.active_record") do |_, _, _, _, payload|
          spec_name = payload[:spec_name] if payload.key?(:spec_name)

          if spec_name
            begin
              connection = ActiveRecord::Base.connection_handler.retrieve_connection(spec_name)
            rescue ConnectionNotEstablished
              connection = nil
            end

            if connection && !@fixture_connections.include?(connection)
              connection.begin_transaction joinable: false
              connection.pool.lock_thread = true if lock_threads
              @fixture_connections << connection
            end
          end
        end

      # Load fixtures for every test.
      else
        ActiveRecord::FixtureSet.reset_cache
        @@already_loaded_fixtures[self.class] = nil
        @loaded_fixtures = load_fixtures(config)
      end

      # Instantiate fixtures for every test if requested.
      instantiate_fixtures if use_instantiated_fixtures
    end
  end
end

module ActiveSupport
  class TestCase
    include ActiveRecord::TestDatabases
    include ActiveRecord::TestFixturesExtension

    class << self
      # Parallelizes the test suite.
      #
      # Takes a +workers+ argument that controls how many times the process
      # is forked. For each process a new database will be created suffixed
      # with the worker number.
      #
      #   test-database-0
      #   test-database-1
      #
      # If <tt>ENV["PARALLEL_WORKERS"]</tt> is set the workers argument will be ignored
      # and the environment variable will be used instead. This is useful for CI
      # environments, or other environments where you may need more workers than
      # you do for local testing.
      #
      # If the number of workers is set to +1+ or fewer, the tests will not be
      # parallelized.
      #
      # If +workers+ is set to +:number_of_processors+, the number of workers will be
      # set to the actual core count on the machine you are on.
      #
      # The default parallelization method is to fork processes. If you'd like to
      # use threads instead you can pass <tt>with: :threads</tt> to the +parallelize+
      # method. Note the threaded parallelization does not create multiple
      # database and will not work with system tests at this time.
      #
      #   parallelize(workers: :number_of_processors, with: :threads)
      #
      # The threaded parallelization uses minitest's parallel executor directly.
      # The processes parallelization uses a Ruby DRb server.
      def parallelize(workers: :number_of_processors, with: :processes)
        workers = Concurrent.physical_processor_count if workers == :number_of_processors
        workers = ENV["PARALLEL_WORKERS"].to_i if ENV["PARALLEL_WORKERS"]

        return if workers <= 1

        executor = case with
                   when :processes
                     Testing::Parallelization.new(workers)
                   when :threads
                     Minitest::Parallel::Executor.new(workers)
                   else
                     raise ArgumentError, "#{with} is not a supported parallelization executor."
        end

        self.lock_threads = false if defined?(self.lock_threads) && with == :threads

        Minitest.parallel_executor = executor

        parallelize_me!
      end

      # Set up hook for parallel testing. This can be used if you have multiple
      # databases or any behavior that needs to be run after the process is forked
      # but before the tests run.
      #
      # Note: this feature is not available with the threaded parallelization.
      #
      # In your +test_helper.rb+ add the following:
      #
      #   class ActiveSupport::TestCase
      #     parallelize_setup do
      #       # create databases
      #     end
      #   end
      def parallelize_setup(&block)
        ActiveSupport::Testing::Parallelization.after_fork_hook do |worker|
          yield worker
        end
      end

      # Clean up hook for parallel testing. This can be used to drop databases
      # if your app uses multiple write/read databases or other clean up before
      # the tests finish. This runs before the forked process is closed.
      #
      # Note: this feature is not available with the threaded parallelization.
      #
      # In your +test_helper.rb+ add the following:
      #
      #   class ActiveSupport::TestCase
      #     parallelize_teardown do
      #       # drop databases
      #     end
      #   end
      def parallelize_teardown(&block)
        ActiveSupport::Testing::Parallelization.run_cleanup_hook do |worker|
          yield worker
        end
      end
    end
  end
end
