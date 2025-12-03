# frozen_string_literal: true

##
# HtmlToBeeConverterService
#
# Converts HTML email templates to Bee Editor compatible JSON format
# using the Beefree HTML Importer API. Handles Blueshift-specific
# merge tags, assets, and creates EmailTemplate records.
#
# Usage:
#   converter = HtmlToBeeConverterService.new(account: current_account)
#   result = converter.convert(html_content, template_name: "My Template")
#
class HtmlToBeeConverterService
  # Beefree API configuration
  BEEFREE_API_BASE = 'https://api.getbee.io/v1'.freeze
  CONVERSION_ENDPOINT = '/conversion/html-to-json'.freeze
  
  # Conversion limits and constraints
  MAX_HTML_SIZE = 2.megabytes
  MAX_CONVERSION_TIME = 30.seconds
  SUPPORTED_MERGE_TAG_FORMATS = %w[liquid handlebars mustache].freeze
  
  # Error classes
  class ConversionError < StandardError; end
  class HTMLValidationError < ConversionError; end
  class BeefreeAPIError < ConversionError; end
  class AssetProcessingError < ConversionError; end

  attr_reader :account, :user, :options

  def initialize(account:, user: nil, **options)
    @account = account
    @user = user
    @options = default_options.merge(options)
  end

  ##
  # Main conversion method
  # 
  # @param html_content [String] The HTML content to convert
  # @param template_name [String] Optional name for the created template
  # @param category [String] Template category (Basic, Newsletter, etc.)
  # @return [Hash] Conversion result with bee_json and email_template
  #
  def convert(html_content, template_name: nil, category: 'Other')
    validate_inputs!(html_content, template_name)
    
    Rails.logger.info "[HtmlToBeeConverter] Starting conversion for account #{account.id}"
    
    conversion_result = {}
    
    ActiveRecord::Base.transaction do
      # Step 1: Preprocess HTML
      preprocessed_html = preprocess_html(html_content)
      conversion_result[:preprocessed_html] = preprocessed_html
      
      # Step 2: Convert to Bee JSON via Beefree API
      bee_json = call_beefree_api(preprocessed_html)
      conversion_result[:bee_json] = bee_json
      
      # Step 3: Adapt for Blueshift
      adapted_json = adapt_for_blueshift(bee_json, html_content)
      conversion_result[:adapted_json] = adapted_json
      
      # Step 4: Create EmailTemplate record
      email_template = create_email_template(
        adapted_json, 
        html_content, 
        template_name, 
        category
      )
      conversion_result[:email_template] = email_template
      
      Rails.logger.info "[HtmlToBeeConverter] Conversion completed successfully"
      conversion_result
    end
    
  rescue StandardError => e
    Rails.logger.error "[HtmlToBeeConverter] Conversion failed: #{e.message}"
    raise ConversionError, "HTML to Bee conversion failed: #{e.message}"
  end

  ##
  # Batch convert multiple HTML templates
  #
  def batch_convert(html_templates)
    results = []
    errors = []
    
    html_templates.each_with_index do |template_data, index|
      begin
        result = convert(
          template_data[:html], 
          template_name: template_data[:name] || "Imported Template #{index + 1}",
          category: template_data[:category] || 'Other'
        )
        results << result.merge(original_data: template_data)
      rescue ConversionError => e
        errors << {
          index: index,
          name: template_data[:name],
          error: e.message
        }
      end
    end
    
    {
      successful: results,
      failed: errors,
      total: html_templates.size,
      success_rate: (results.size.to_f / html_templates.size * 100).round(1)
    }
  end

  private

  def default_options
    {
      process_assets: true,
      preserve_html: true,
      validate_bee_json: true,
      merge_tag_format: 'liquid',
      timeout: MAX_CONVERSION_TIME
    }
  end

  def validate_inputs!(html_content, template_name)
    if html_content.blank?
      raise HTMLValidationError, "HTML content cannot be empty"
    end
    
    if html_content.bytesize > MAX_HTML_SIZE
      raise HTMLValidationError, "HTML content exceeds maximum size of #{MAX_HTML_SIZE / 1.megabyte}MB"
    end
    
    unless html_content.include?('<html') && html_content.include?('<body')
      raise HTMLValidationError, "HTML must contain proper document structure with <html> and <body> tags"
    end
  end

  def preprocess_html(html_content)
    # Add DOCTYPE if missing
    html = html_content.dup
    html = "<!DOCTYPE html>\n#{html}" unless html.start_with?('<!DOCTYPE')
    
    # Ensure charset
    unless html.include?('charset=')
      html = html.sub(/(<head[^>]*>)/i, "\\1\n    <meta charset=\"UTF-8\">")
    end
    
    # Convert merge tags to Blueshift format
    html = convert_merge_tags(html)
    
    html
  end

  def convert_merge_tags(html)
    # Convert common patterns to Blueshift format
    html.gsub(/\{\{\s*first_?name\s*\}\}/i, '{{user.first_name}}')
        .gsub(/\{\{\s*last_?name\s*\}\}/i, '{{user.last_name}}')
        .gsub(/\{\{\s*email\s*\}\}/i, '{{user.email}}')
        .gsub(/href=["']([^"']*unsubscribe[^"']*)["']/i, 'href="{{unsubscribe_link}}"')
  end

  def call_beefree_api(html_content)
    # Mock implementation for now - would call actual Beefree API
    {
      "page" => {
        "body" => {
          "content" => {
            "style" => {
              "font-family" => "Arial, sans-serif"
            }
          }
        },
        "rows" => [
          {
            "type" => "one-column-empty",
            "columns" => [
              {
                "grid-columns" => 12,
                "modules" => [
                  {
                    "type" => "mailup-bee-newsletter-modules-text",
                    "descriptor" => {
                      "text" => {
                        "html" => extract_body_content(html_content)
                      }
                    }
                  }
                ]
              }
            ]
          }
        ]
      }
    }
  end

  def adapt_for_blueshift(bee_json, original_html)
    # Add Blueshift-specific configuration
    bee_json['blueshift'] = {
      'version' => '1.0',
      'editor_type' => 'visual',
      'account_uuid' => account.uuid,
      'conversion_metadata' => {
        'source' => 'html_import',
        'converted_at' => Time.current.iso8601,
        'original_html_size' => original_html.bytesize,
        'merge_tags_count' => original_html.scan(/\{\{[^}]+\}\}/).size
      }
    }
    
    bee_json
  end

  def create_email_template(bee_json, html_content, template_name, category)
    template_name ||= "HTML Import #{Time.current.strftime('%Y%m%d_%H%M%S')}"
    
    email_template = account.email_templates.build(
      name: template_name,
      editor_type: 'visual',
      bee_editor_json: bee_json,
      content: options[:preserve_html] ? html_content : nil,
      subject: extract_subject_from_html(html_content),
      category: category,
      created_by: user
    )
    
    email_template.save!
    email_template
  end

  def extract_body_content(html)
    doc = Nokogiri::HTML(html)
    body = doc.at_css('body')
    body ? body.inner_html : html
  end

  def extract_subject_from_html(html)
    doc = Nokogiri::HTML(html)
    title_tag = doc.at_css('title')
    title_tag&.text&.strip || 'Imported Template'
  end
end