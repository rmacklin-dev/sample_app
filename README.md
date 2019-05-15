# rails_parallel_testing_experiments

This repository contains some of my experimentation with Rails 6 parallel
testing.

---

I found an issue that others might run into ([rails/rails#36288]). I've been
able to work around it, but I still opened that issue on the rails repository to
see if we want to do something within rails to address it.

[rails/rails#36288]: https://github.com/rails/rails/issues/36288

### Steps to reproduce

I [created a new rails 6.0.0.rc1 app] and [added a dummy system test]. I
configured it to run tests in parallel, and set it up to run on CircleCI.

[added a dummy system test]: https://github.com/rmacklin/rails_parallel_testing_experiments/commit/bdc34511d9b34c1b456bfcf14702434307d06cde
[created a new rails 6.0.0.rc1 app]: https://github.com/rmacklin/rails_parallel_testing_experiments/commit/736688f2f11b27b7226bc6ba9dbcc94f5ab6deaa

### Expected behavior

The tests pass on CI

### Actual behavior

The tests can fail on CI with the following error:
```
ChildProcess::LaunchError: Text file busy - /home/circleci/.webdrivers/chromedriver
    test/system/sample_system_test.rb:19:in `block in <class:SampleSystemTest>'
```

Example CI build:
https://circleci.com/gh/rmacklin/rails_parallel_testing_experiments/16

I think the error stems from multiple forked processes trying to update
chromedriver in parallel. I've configured the sample app to use 2 parallel
workers, but it follows that this error will be more common as more parallel
workers are used.

My workaround was to explicitly trigger a chromedriver update before parallel
processes are forked: [`4b3b06b`]

[`4b3b06b`]: https://github.com/rmacklin/rails_parallel_testing_experiments/commit/4b3b06bbeb34ec57277c8b37ad3804cd659539db

---

I also experimented with backporting Rails 6 parallel testing support to a
Rails 5 application. You can see a working example in the [`rails-5` branch]
and a description in this gist:
https://gist.github.com/rmacklin/686a3d284147c009e305527f32abfccd

[`rails-5` branch]: https://github.com/rmacklin/rails_parallel_testing_experiments/tree/rails-5
