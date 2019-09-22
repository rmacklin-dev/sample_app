require "application_system_test_case"

class SampleSystemTest < ApplicationSystemTestCase
  test "visiting the index" do
    visit root_url

    assert_selector "h1", text: "Home#indexFAIL"
  end

  test "visiting the index slow1" do
    visit root_url

    sleep 1

    assert_selector "h1", text: "Home#index"
  end

  test "visiting the index slow2" do
    visit root_url

    sleep 2

    assert_selector "h1", text: "Home#index"
  end

  test "visiting the index slow3" do
    visit root_url

    sleep 3

    assert_selector "h1", text: "Home#index"
  end

  test "visiting the index slow4" do
    visit root_url

    sleep 1

    assert_selector "h1", text: "Home#index"
  end

  test "visiting the index slow5" do
    visit root_url

    sleep 2

    assert_selector "h1", text: "Home#index"
  end

  test "visiting the index slow6" do
    visit root_url

    sleep 3

    assert_selector "h1", text: "Home#index"
  end
end
