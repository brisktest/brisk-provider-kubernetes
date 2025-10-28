# frozen_string_literal: true

require_relative "brisk/providers/kubernetes/engine"
require_relative "brisk/providers/kubernetes/pod_service"
require_relative "brisk/providers/kubernetes/provider"

module Brisk
  module Providers
    module Kubernetes
      VERSION = "1.0.0"
    end
  end
end
