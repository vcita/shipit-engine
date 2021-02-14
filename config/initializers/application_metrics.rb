require 'vcita/infra'

# Configure Application Metrics
monitor = Vcita::Infra::ApplicationMetrics
monitor.registry.counter(:predictive_builds, docstring:'Pipeline - Predictive Build', labels: [:pipeline, :final_result, :duration, :mode])
monitor.registry.counter(:predictive_branches, docstring:'Stack - Predictive Branch', labels: [:pipeline, :final_result, :duration, :repository])
monitor.registry.counter(:deploys, docstring:'Deploys', labels: [:final_result, :duration, :repository])
monitor.registry.counter(:merge_requests, docstring:'Merge Requests', labels: [:id, :final_result, :duration, :repository])