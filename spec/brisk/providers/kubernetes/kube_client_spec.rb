# frozen_string_literal: true

require 'rails_helper'
require 'brisk/providers/kubernetes/kube_client'

RSpec.describe Brisk::Providers::Kubernetes::KubeClient do
  let(:test_token) { 'test-service-account-token' }
  let(:test_api_url) { 'https://kubernetes.default.svc' }
  let(:http) { instance_double(Net::HTTP) }

  def mock_response(code, body)
    response = instance_double(Net::HTTPResponse, code: code.to_s, body: body)
    allow(response).to receive(:is_a?).with(anything).and_return(false)
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(code == 200)
    response
  end

  def pods_json(pods)
    {
      'kind' => 'PodList',
      'items' => pods.map do |pod|
        {
          'metadata' => { 'name' => pod[:name] },
          'status' => { 'phase' => pod[:status], 'podIP' => pod[:ip] }
        }
      end
    }.to_json
  end

  describe '.in_cluster?' do
    it 'returns true when service account token exists' do
      allow(File).to receive(:exist?)
        .with("#{described_class::SERVICE_ACCOUNT_DIR}/token")
        .and_return(true)

      expect(described_class.in_cluster?).to be true
    end

    it 'returns false when service account token does not exist' do
      allow(File).to receive(:exist?)
        .with("#{described_class::SERVICE_ACCOUNT_DIR}/token")
        .and_return(false)

      expect(described_class.in_cluster?).to be false
    end
  end

  describe '#initialize' do
    it 'uses provided token instead of reading from filesystem' do
      client = described_class.new(token: test_token)
      expect(client).to be_a(described_class)
    end

    it 'raises KubeApiError when no token provided and file missing' do
      allow(File).to receive(:read)
        .with("#{described_class::SERVICE_ACCOUNT_DIR}/token")
        .and_raise(Errno::ENOENT)

      expect { described_class.new }.to raise_error(
        Brisk::Providers::Kubernetes::KubeApiError,
        /Service account token not found/
      )
    end
  end

  describe '#list_pods' do
    let(:client) { described_class.new(api_url: test_api_url, token: test_token, ca_cert_path: '/nonexistent/ca.crt') }

    before do
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:verify_mode=)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/nonexistent/ca.crt').and_return(false)
    end

    it 'parses K8s API response into pod hashes' do
      body = pods_json([
                         { name: 'worker-abc', status: 'Running', ip: '10.0.0.1' },
                         { name: 'worker-def', status: 'Running', ip: '10.0.0.2' }
                       ])
      allow(http).to receive(:request).and_return(mock_response(200, body))

      pods = client.list_pods(namespace: 'brisk-test')

      expect(pods).to eq([
                           { name: 'worker-abc', status: 'Running', ip: '10.0.0.1' },
                           { name: 'worker-def', status: 'Running', ip: '10.0.0.2' }
                         ])
    end

    it 'returns empty array when no pods exist' do
      body = { 'kind' => 'PodList', 'items' => [] }.to_json
      allow(http).to receive(:request).and_return(mock_response(200, body))

      pods = client.list_pods(namespace: 'brisk-test')

      expect(pods).to eq([])
    end

    it 'handles missing items key gracefully' do
      body = { 'kind' => 'PodList' }.to_json
      allow(http).to receive(:request).and_return(mock_response(200, body))

      pods = client.list_pods(namespace: 'brisk-test')

      expect(pods).to eq([])
    end

    it 'includes label_selector as query parameter' do
      body = { 'kind' => 'PodList', 'items' => [] }.to_json
      allow(http).to receive(:request) do |request|
        expect(request.path).to include('labelSelector=app%3Dworker')
        mock_response(200, body)
      end

      client.list_pods(namespace: 'brisk-test', label_selector: 'app=worker')
    end

    it 'makes request to correct namespace path' do
      body = { 'kind' => 'PodList', 'items' => [] }.to_json
      allow(http).to receive(:request) do |request|
        expect(request.path).to start_with('/api/v1/namespaces/my-namespace/pods')
        mock_response(200, body)
      end

      client.list_pods(namespace: 'my-namespace')
    end

    it 'sets Authorization bearer header' do
      body = { 'kind' => 'PodList', 'items' => [] }.to_json
      allow(http).to receive(:request) do |request|
        expect(request['Authorization']).to eq("Bearer #{test_token}")
        mock_response(200, body)
      end

      client.list_pods(namespace: 'brisk-test')
    end

    context 'when CA cert file does not exist' do
      it 'logs a warning about disabled SSL verification' do
        logger = instance_double(Logger)
        allow(Rails).to receive(:logger).and_return(logger)
        body = { 'kind' => 'PodList', 'items' => [] }.to_json
        expect(http).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_NONE)
        expect(logger).to receive(:warn).with(/CA cert not found.*SSL verification disabled/)
        allow(http).to receive(:request).and_return(mock_response(200, body))

        client.list_pods(namespace: 'brisk-test')
      end
    end

    context 'when CA cert file exists' do
      before do
        allow(File).to receive(:exist?).with('/nonexistent/ca.crt').and_return(true)
      end

      it 'configures SSL with CA cert' do
        body = { 'kind' => 'PodList', 'items' => [] }.to_json
        expect(http).to receive(:ca_file=).with('/nonexistent/ca.crt')
        expect(http).to receive(:verify_mode=).with(OpenSSL::SSL::VERIFY_PEER)
        allow(http).to receive(:request).and_return(mock_response(200, body))

        client.list_pods(namespace: 'brisk-test')
      end
    end

    context 'when encountering errors' do
      it 'raises KubeApiError on non-200 response' do
        allow(http).to receive(:request).and_return(mock_response(403, 'Forbidden'))

        expect { client.list_pods(namespace: 'brisk-test') }.to raise_error(
          Brisk::Providers::Kubernetes::KubeApiError,
          /K8s API returned 403/
        )
      end

      it 'raises KubeApiError on connection refused' do
        allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

        expect { client.list_pods(namespace: 'brisk-test') }.to raise_error(
          Brisk::Providers::Kubernetes::KubeApiError,
          /Failed to connect to K8s API/
        )
      end

      it 'raises KubeApiError on timeout' do
        allow(http).to receive(:request).and_raise(Net::OpenTimeout)

        expect { client.list_pods(namespace: 'brisk-test') }.to raise_error(
          Brisk::Providers::Kubernetes::KubeApiError,
          /Failed to connect to K8s API/
        )
      end

      it 'raises KubeApiError on SSL error' do
        allow(http).to receive(:request).and_raise(OpenSSL::SSL::SSLError.new('certificate verify failed'))

        expect { client.list_pods(namespace: 'brisk-test') }.to raise_error(
          Brisk::Providers::Kubernetes::KubeApiError,
          /Failed to connect to K8s API/
        )
      end

      it 'raises KubeApiError on host unreachable' do
        allow(http).to receive(:request).and_raise(Errno::EHOSTUNREACH)

        expect { client.list_pods(namespace: 'brisk-test') }.to raise_error(
          Brisk::Providers::Kubernetes::KubeApiError,
          /Failed to connect to K8s API/
        )
      end

      it 'raises KubeApiError on read timeout' do
        allow(http).to receive(:request).and_raise(Net::ReadTimeout)

        expect { client.list_pods(namespace: 'brisk-test') }.to raise_error(
          Brisk::Providers::Kubernetes::KubeApiError,
          /Failed to connect to K8s API/
        )
      end

      it 'raises KubeApiError on DNS resolution failure' do
        allow(http).to receive(:request).and_raise(SocketError.new('getaddrinfo: Name or service not known'))

        expect { client.list_pods(namespace: 'brisk-test') }.to raise_error(
          Brisk::Providers::Kubernetes::KubeApiError,
          /Failed to connect to K8s API/
        )
      end
    end
  end
end
