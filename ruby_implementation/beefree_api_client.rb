# frozen_string_literal: true

##
# BeefreeApiClient - Handles communication with Beefree HTML Importer API
#
class BeefreeApiClient
  include HTTParty
  
  base_uri 'https://api.getbee.io/v1'
  
  # API endpoints
  HTML_TO_JSON_ENDPOINT = '/conversion/html-to-json'.freeze
  
  # Default options
  DEFAULT_TIMEOUT = 30
  DEFAULT_HEADERS = {
    'Content-Type' => 'application/json',
    'Accept' => 'application/json'
  }.freeze

  def initialize(api_token: nil)
    @api_token = api_token || Rails.application.credentials.beefree_api_token
    raise ArgumentError, "Beefree API token is required" unless @api_token
    
    @default_headers = DEFAULT_HEADERS.merge({
      'Authorization' => "Bearer #{@api_token}"
    })
  end

  ##
  # Convert HTML to Bee Editor JSON
  #
  # @param html [String] The HTML content to convert
  # @param options [Hash] Additional options
  # @return [Hash] API response with success/error status
  #
  def convert_html_to_json(html:, options: {})
    start_time = Time.current
    
    Rails.logger.info "[BeefreeApiClient] Starting HTML to JSON conversion"
    
    request_body = {
      html: html,
      options: build_conversion_options(options)
    }
    
    begin
      response = self.class.post(
        HTML_TO_JSON_ENDPOINT,
        {
          body: request_body.to_json,
          headers: @default_headers,
          timeout: options[:timeout] || DEFAULT_TIMEOUT
        }
      )
      
      duration = Time.current - start_time
      Rails.logger.info "[BeefreeApiClient] API call completed in #{duration.round(3)}s"
      
      handle_response(response)
      
    rescue Net::TimeoutError, HTTParty::TimeoutError => e
      Rails.logger.error "[BeefreeApiClient] Timeout error: #{e.message}"
      {
        success: false,
        error: "API request timed out after #{options[:timeout] || DEFAULT_TIMEOUT}s",
        error_type: 'timeout'
      }
    rescue StandardError => e
      Rails.logger.error "[BeefreeApiClient] Unexpected error: #{e.message}"
      {
        success: false,
        error: "Unexpected error: #{e.message}",
        error_type: 'unknown'
      }
    end
  end

  ##
  # Validate API credentials and connectivity
  #
  def test_connection
    test_html = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Test</title></head><body><p>Test</p></body></html>'
    
    result = convert_html_to_json(html: test_html, options: { timeout: 10 })
    
    if result[:success]
      {
        status: 'connected',
        message: 'Successfully connected to Beefree API',
        response_time: result[:response_time]
      }
    else
      {
        status: 'error',
        message: "Connection failed: #{result[:error]}",
        error_type: result[:error_type]
      }
    end
  end

  private

  def handle_response(response)
    case response.code
    when 200..299
      parsed_response = JSON.parse(response.body)
      {
        success: true,
        json: parsed_response['json'] || parsed_response,
        html: parsed_response['html'],
        metadata: parsed_response['metadata'] || {},
        response_time: parsed_response['response_time']
      }
    when 400
      error_details = parse_error_response(response)
      {
        success: false,
        error: error_details[:message],
        error_type: 'validation_error',
        details: error_details[:details]
      }
    when 401
      {
        success: false,
        error: "Invalid or expired API token",
        error_type: 'authentication_error'
      }
    when 422
      error_details = parse_error_response(response)
      {
        success: false,
        error: error_details[:message],
        error_type: 'content_error',
        details: error_details[:details]
      }
    when 429
      retry_after = response.headers['Retry-After'] || '60'
      {
        success: false,
        error: "Rate limit exceeded. Retry after #{retry_after} seconds",
        error_type: 'rate_limit',
        retry_after: retry_after.to_i
      }
    when 500..599
      {
        success: false,
        error: "Beefree API server error (#{response.code})",
        error_type: 'server_error'
      }
    else
      {
        success: false,
        error: "Unexpected API response (#{response.code})",
        error_type: 'unknown_error'
      }
    end
  end

  def parse_error_response(response)
    begin
      parsed = JSON.parse(response.body)
      {
        message: parsed['error'] || parsed['message'] || 'Unknown error',
        details: parsed['details'] || parsed['errors'] || []
      }
    rescue JSON::ParserError
      {
        message: "API returned non-JSON error response",
        details: [response.body.truncate(200)]
      }
    end
  end

  def build_conversion_options(options)
    {
      minify: options[:minify] || false,
      prettify: options[:prettify] || true,
      preserve_comments: options[:preserve_comments] || false,
      inline_css: options[:inline_css] || true,
      preserve_merge_tags: options[:preserve_merge_tags] || true,
      merge_tag_format: options[:merge_tag_format] || 'liquid'
    }.compact
  end
end