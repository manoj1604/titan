require "minitest/autorun"
require "rack/test"
require_relative "../app"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app = App.new

  def test_health_reports_linux
    get "/health"
    assert_equal 200, last_response.status
    assert_match(/linux/, JSON.parse(last_response.body)["platform"])
  end

  def test_unknown_path
    get "/nope"
    assert_equal 404, last_response.status
  end
end
