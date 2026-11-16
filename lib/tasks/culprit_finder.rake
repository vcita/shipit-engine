# frozen_string_literal: true
namespace :culprit_finder do
  desc "Prints the accuracy of the culprit finder. DAYS=7 ENVIRONMENT=integration"
  task report: :environment do
    days = ENV.fetch('DAYS', '7').to_i
    puts Shipit::CulpritFinderReport.new(since: days.days.ago, environment: ENV['ENVIRONMENT'].presence)
  end
end
