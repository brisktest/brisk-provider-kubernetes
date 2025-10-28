# frozen_string_literal: true

FactoryBot.define do
  factory :project do
    worker_provider { 'kubernetes' }
    provider_config { {} }
    image { 'ruby:3.3' }
  end

  factory :worker do
    association :project
    association :machine, factory: :machine, strategy: :build
  end

  factory :machine do
    association :project
    provider { 'kubernetes' }
    uid { "pod-#{SecureRandom.hex(6)}" }
    state { 'running' }
  end
end
