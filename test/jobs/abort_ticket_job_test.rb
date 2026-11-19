# frozen_string_literal: true
require 'test_helper'

module Shipit
  class AbortTicketJobTest < ActiveSupport::TestCase
    test "#perform stops the checks of the commit" do
      TicketRun.any_instance.expects(:abort).once

      AbortTicketJob.new.perform(shipit_stacks(:shipit), 'a' * 40, 'feature-62')
    end
  end
end
