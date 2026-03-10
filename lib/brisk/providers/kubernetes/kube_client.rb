# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'openssl'

module Brisk
  module Providers
    module Kubernetes
      class KubeApiError < StandardError; end

      # Lightweight Kubernetes API client for in-cluster use.
      # Uses the pod's service account credentials to authenticate.
      # Only supports read operations needed for reconciliation.
      class KubeClient
        SERVICE_ACCOUNT_DIR = '/var/run/secrets/kubernetes.io/serviceaccount'
        DEFAULT_API_URL = 'https://kubernetes.default.svc'

        def self.in_cluster?
          File.exist?(File.join(SERVICE_ACCOUNT_DIR, 'token'))
        end

        def initialize(api_url: DEFAULT_API_URL, token: nil, ca_cert_path: nil)
          @api_url = api_url
          @token = token || read_service_account_token
          @ca_cert_path = ca_cert_path || File.join(SERVICE_ACCOUNT_DIR, 'ca.crt')
        end

        # List pods in a namespace, optionally filtered by label selector.
        # Returns an array of hashes: [{ name:, status:, ip: }, ...]
        def list_pods(namespace:, label_selector: nil)
          path = "/api/v1/namespaces/#{namespace}/pods"
          path += "?labelSelector=#{URI.encode_www_form_component(label_selector)}" if label_selector

          response = get(path)
          items = response['items'] || []
          items.map do |pod|
            {
              name: pod.dig('metadata', 'name'),
              status: pod.dig('status', 'phase'),
              ip: pod.dig('status', 'podIP')
            }
          end
        end

        private

        def read_service_account_token
          File.read(File.join(SERVICE_ACCOUNT_DIR, 'token')).strip
        rescue Errno::ENOENT
          raise KubeApiError, "Service account token not found at #{SERVICE_ACCOUNT_DIR}/token"
        end

        def get(path)
          uri = URI("#{@api_url}#{path}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == 'https')
          http.open_timeout = 5
          http.read_timeout = 10

          if File.exist?(@ca_cert_path)
            http.ca_file = @ca_cert_path
            http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          else
            Rails.logger&.warn "[K8s] CA cert not found at #{@ca_cert_path}, SSL verification disabled"
            http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          end

          request = Net::HTTP::Get.new(uri)
          request['Authorization'] = "Bearer #{@token}"
          request['Accept'] = 'application/json'

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            raise KubeApiError, "K8s API returned #{response.code}: #{response.body&.slice(0, 200)}"
          end

          JSON.parse(response.body)
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Net::OpenTimeout,
               Net::ReadTimeout, OpenSSL::SSL::SSLError, SocketError => e
          raise KubeApiError, "Failed to connect to K8s API at #{@api_url}: #{e.message}"
        end
      end
    end
  end
end
