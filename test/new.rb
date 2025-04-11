# typed: true
# frozen_string_literal: true

require "csv"
require "faraday"
require "github/sendgrid/error"

module Nurture
  class SendgridImportJob < ApplicationJob

    def perform(data)
      return unless self.class.job_ff_enabled?
      return unless self.class.env_vars_present?

      if data.empty?
        GitHub.logger.info(
          "error.message" => "No contact emails sent to import job",
        )
      end
   end
 end
end
