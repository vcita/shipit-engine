# frozen_string_literal: true
module Shipit
  # Tracks consecutive dead/errored verify polls in redis. A verify task is an
  # idempotent CI status poll running every minute: losing one (worker died,
  # reaped as zombie, transient error) says nothing about the CI itself, so a
  # few strikes are tolerated before the owner declares failure.
  module VerifyPollStrikes
    extend ActiveSupport::Concern

    # Polls run every minute, so this adds at most ~4 minutes before a
    # genuinely broken pipeline is declared failed.
    MAX_VERIFY_POLL_STRIKES = 3

    def verify_poll_strikes_key
      "#{self.class.name}::verify_poll_strikes_#{id}"
    end

    def verify_poll_strikes_exhausted?
      strikes = Shipit.redis.incr(verify_poll_strikes_key)
      Shipit.redis.expire(verify_poll_strikes_key, 1.day.to_i)
      strikes > MAX_VERIFY_POLL_STRIKES
    end

    def clear_verify_poll_strikes
      Shipit.redis.del(verify_poll_strikes_key)
    end
  end
end
