# frozen_string_literal: true
namespace :culprit_finder do
  desc "Prints the accuracy of the culprit finder. DAYS=7 ENVIRONMENT=integration MIN_CONFIDENCE=0.7"
  task report: :environment do
    puts Shipit::CulpritFinderReport.new(
      since: ENV.fetch('DAYS', '7').to_i.days.ago,
      environment: ENV['ENVIRONMENT'].presence,
      min_confidence: ENV.fetch('MIN_CONFIDENCE', '0').to_f,
    )
  end
end
