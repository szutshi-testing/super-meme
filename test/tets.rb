# typed: true
# frozen_string_literal: true

require "csv"
require "faraday"
require "github/sendgrid/error"

module Nurture
  class SendgridImportJob < ApplicationJob
    retry_on_dirty_exit
    retry_on_recoverable_exceptions attempts: 5
    retry_on GitHub::Sendgrid::Error, wait: :polynomially_longer, attempts: 5

    queue_as :nurture_campaign_sync

    # https://www.twilio.com/docs/sendgrid/api-reference/custom-fields/get-all-field-definitions
    SENDGRID_EMAIL_FIELD = "_rf2_T"
    SENDGRID_LOGIN_FIELD = "w1_T"
    SENDGRID_UNSUBSCRIBE_URL_FIELD = "e3_T"

    BASE_URL = "https://api.sendgrid.com"

    def perform(data)
      return unless self.class.job_ff_enabled?
      return unless self.class.env_vars_present?

      if data.empty?
        GitHub.logger.info(
          "error.message" => "No contact emails sent to import job",
        )

        GitHub.dogstats.increment("nurture_campaign.sendgrid_import_job.error", tags: ["error:no_data"])
        return
      end

      if GitHub.flipper[:nurture_campaign_staff_testing].enabled?
        GitHub.logger.info(
          "info.message" => "Staff testing is enabled.  Logging payload.",
          "gh.nurture.sendgrid_import_job.data.count" => data.count,
          "gh.nurture.sendgrid_import_job.data" => data.to_s,
        )
      end

      GitHub.dogstats.time("nurture_campaign.sendgrid_import_job") do
        GitHub.dogstats.increment("nurture_campaign.sendgrid_import_job.start")
        GitHub.dogstats.count("nurture_campaign.sendgrid_import_job.data.count", data.count)

        GitHub.logger.info(
          "info.message" => "Starting sendgrid import job",
          "gh.nurture.sendgrid_import_job.data.count" => data.count,
        )

        field_mappings = [
          SENDGRID_EMAIL_FIELD,
          SENDGRID_LOGIN_FIELD,
          SENDGRID_UNSUBSCRIBE_URL_FIELD,
        ]

        begin
          import_request_data = self.class.request_import_from_sendgrid(field_mappings)

          # Parse the response to get the job_id, upload_uri, and upload_headers
          # https://www.twilio.com/docs/sendgrid/api-reference/contacts/import-contacts#responses
          job_id = import_request_data["job_id"]
          upload_uri = import_request_data["upload_uri"]
          upload_headers = import_request_data["upload_headers"]

          GitHub.logger.info(
            "info.message" => "Created sendgrid import job",
            "gh.nurture.sendgrid_import_job.job_id" => job_id,
            "gh.nurture.sendgrid_import_job.upload_uri" => upload_uri,
            "gh.nurture.sendgrid_import_job.upload_headers" => upload_headers,
          )

          csv_data = self.class.generate_csv(data, field_mappings)

          if GitHub.flipper[:nurture_campaign_staff_testing].enabled?
            GitHub.logger.info(
              "info.message" => "Staff testing is enabled.  Logging payload.",
              "gh.nurture.cpm_sync_job.csv_data.payload" => csv_data,
            )
          end

          self.class.upload_csv_file_to_sendgrid(upload_uri, upload_headers, csv_data, job_id)

          GitHub.dogstats.increment("nurture_campaign.sendgrid_import_job.finish")
        rescue JSON::ParserError => err
          GitHub.logger.error(
            "error.message" => "Error parsing JSON response from Sendgrid",
            "error.body" => err.message,
            "gh.nurture.sendgrid_import_job.job_id" => job_id,
          )

          GitHub.dogstats.increment("nurture_campaign.sendgrid_import_job.error", tags: ["error:json_parse"])
        rescue Faraday::Error => err
          GitHub.logger.error(
            "error.message" => "Error importing contacts to Sendgrid",
            "error.status" => err.response[:status],
            "error.body" => err.response[:body],
            "gh.nurture.sendgrid_import_job.job_id" => job_id,
          )

          raise GitHub::Sendgrid::Error.new(err, :import)
        end
      end
    end

    def self.job_ff_enabled?
      return true if GitHub.flipper[:run_nurture_campaign_jobs].enabled?

      GitHub.logger.info(
        "info.message" => "run_nurture_campaign_jobs FF is disabled.  Skipping job.",
      )

      GitHub.dogstats.increment("nurture_campaign.sendgrid_import_job.skipped", tags: ["skipped:ff_disabled"])

      false
    end

    def self.env_vars_present?
      return true if ENV["SIGNUP_SENDGRID_API_KEY"].present? &&
                     ENV["SIGNUP_SENDGRID_NURTURE_LIST_ID"].present?

      GitHub.logger.error(
        "error.message" => "SIGNUP_SENDGRID_API_KEY or SIGNUP_SENDGRID_NURTURE_LIST_ID environment variable is not set",
      )

      GitHub.dogstats.increment("nurture_campaign.sendgrid_import_job.error", tags: ["error:missing_env"])

      false
    end

    def self.import_url
      "/v3/marketing/contacts/imports"
    end

    sig { params(field_mappings: T::Array[String]).returns(T::Hash[String, T.untyped]) }
    def self.request_import_from_sendgrid(field_mappings)
      # Sendgrid API v3
      sg = GitHub::FaradayClient.external("Sendgrid", BASE_URL)

      # Request to create a new import job
      # https://www.twilio.com/docs/sendgrid/api-reference/contacts/import-contacts
      resp = sg.put do |req|
        req.url import_url
        req.headers["Authorization"] = "Bearer #{ENV["SIGNUP_SENDGRID_API_KEY"]}"
        req.headers["Content-Type"] = "application/json"
        req.body = GitHub::JSON.encode({
          list_ids: [ENV["SIGNUP_SENDGRID_NURTURE_LIST_ID"]],
          file_type: "csv",
          field_mappings:
        })
      end

      GitHub.logger.info(
        "info.message" => "Sendgrid import job request success",
      )

      GitHub.dogstats.increment("nurture_campaign.sendgrid_import_job.request", tags: ["status:#{resp.status}"])

      if resp.status != 200
        GitHub.logger.error(
          "error.message" => "Error making Sendgrid import job request",
          "error.status" => resp.status,
          "error.body" => resp.body,
        )

        raise GitHub::Sendgrid::Error.new(resp, :import)
      end

      JSON.parse(resp.body)
    end

    sig { params(data: T::Array[Nurture::SendgridData], field_mappings: T::Array[String]).returns(String) }
    def self.generate_csv(data, field_mappings)
      CSV.generate(headers: true) do |csv|
        csv << field_mappings
        data.each do |d|
          sgd = SendgridData.from_serialized_hash(d)
          csv << [sgd.email, sgd.display_login, sgd.unsub_url]
        end
      end
    end

    sig { params(upload_uri: String, upload_headers: T::Array[T::Hash[String, String]], csv_data: String, job_id: String).void }
    def self.upload_csv_file_to_sendgrid(upload_uri, upload_headers, csv_data, job_id)
      Tempfile.create(anonymous: true) do |file|
        file.write(csv_data)
        file.rewind

        csv_upload = GitHub::FaradayClient.external("Sendgrid", upload_uri)

        resp = csv_upload.put do |req|
          # Map the provided headers for the upload request
          upload_headers.each do |header|
            req.headers[header["header"]] = header["value"]
          end
          req.body = file.read
        end

        GitHub.logger.info(
          "info.message" => "Sendgrid upload success",
          "gh.nurture.sendgrid_import_job.job_id" => job_id,
        )

        GitHub.dogstats.increment("nurture_campaign.sendgrid_import_job.upload", tags: ["status:#{resp.status}"])

        if resp.status != 200
          GitHub.logger.error(
            "error.message" => "Error uploading contacts to Sendgrid",
            "error.status" => resp.status,
            "error.body" => resp.body,
            "gh.nurture.sendgrid_import_job.job_id" => job_id,
          )

          raise GitHub::Sendgrid::Error.new(resp, :import)
        end
      end
    end
  end
end
