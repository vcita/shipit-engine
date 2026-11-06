# frozen_string_literal: true
ENV["RAILS_ENV"] ||= "test"

require 'simplecov'
SimpleCov.start('rails') do
  enable_coverage :branch
end

require 'webmock/minitest'

require File.expand_path('../../test/dummy/config/environment.rb', __FILE__)
# The pending-migration check reads Migrator.migrations_paths, not the app paths (see test/dummy/config/application.rb).
ActiveRecord::Migrator.migrations_paths = Rails.application.paths['db/migrate'].to_a
require 'rails/test_help'
require 'mocha/minitest'
require 'spy/integration'

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_path=)
  ActiveSupport::TestCase.fixture_path = File.expand_path("../fixtures", __FILE__)
  ActiveSupport::TestCase.fixtures(:all)
end

Dir[File.expand_path('../helpers/**/*.rb', __FILE__)].each do |helper|
  require helper
end

begin
  require 'pry'
rescue LoadError
end

# This fork merges without status checks (a TODO in MergeRequest), so tests of that gate cannot pass.
STATUS_CHECKS_BYPASSED = 'MergeRequest#all_status_checks_passed? always returns true in the vcita fork'

module ActiveSupport
  class TestCase
    include PayloadsHelper
    include TasksHelper
    include FixtureAliasesHelper
    include QueriesHelper
    include JSONHelper
    include LinksHelper
    include ApiHelper
    include HooksHelper
    include ActiveJob::TestHelper

    setup do
      @routes = Shipit::Engine.routes
      Shipit.github.api.stubs(:login).returns('shipit')
    end

    teardown do
      Shipit.redis.flushdb
      Shipit.instance_variable_names.each do |name|
        next if %w(@mocha @redis).include?(name)
        Shipit.remove_instance_variable(name)
      end
    end

    ActiveRecord::Migration.check_pending!

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    #
    # Note: You'll currently still have to declare fixtures explicitly in integration tests
    # -- they do not yet inherit this setting
    fixtures :all

    # Add more helper methods to be used by all tests here...
    private

    def resource(data)
      Sawyer::Resource.new(Sawyer::Agent.new('http://example.com'), data)
    end
  end
end
