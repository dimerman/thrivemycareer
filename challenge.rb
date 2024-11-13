#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'logger'
require 'stringio'

# The ChallengeLogger module provides a centralized logger instance for the application.
# It allows configuration of the logging level and output destination to ensure consistent logging.
module ChallengeLogger
  def self.logger
    @logger ||= Logger.new($stdout)
  end

  def self.configure(level: Logger::INFO, output: $stdout)
    @logger = Logger.new(output)
    @logger.level = level
  end
end

# The User class represents an individual user with personal and account-related attributes.
# It ensures that all required attributes are present, validates that "email_status" and
# "active_status" are boolean values, and that "tokens" is a numeric value. Users can
# process token top-ups based on their associated company's "top_up" amount and determine
# their eligibility to receive emails based on both user and company email statuses.
# It's initialized with an actual instance of Company based on the raw data's "company_id" value.
class User
  FILENAME = 'users.json'
  attr_accessor :id, :first_name, :last_name, :email, :company, :email_status, :active_status, :tokens

  def initialize(attrs = {})
    @id = attrs['id']
    @first_name = attrs['first_name']
    @last_name = attrs['last_name']
    @email = attrs['email']
    @company = attrs['company']
    @email_status = attrs['email_status']
    @active_status = attrs['active_status']
    @tokens = attrs['tokens']
    validate!
  end

  def process_top_up(output_file)
    previous_token_amount = @tokens
    top_up_amount = top_up_tokens
    return 0 if top_up_amount.zero?

    output_file.puts "\t#{@last_name}, #{@first_name}, #{@email}"
    output_file.puts "\t\tPrevious Token Balance, #{previous_token_amount}"
    output_file.puts "\t\tNew Token Balance #{@tokens}"
    top_up_amount
  end

  def should_send_email?
    email_status && company.email_status
  end

  # Reads and parses the 'users.json' file, associating each user with their Company based on company_id.
  # Returns a hash grouping User instances by their associated company's id.
  # @return Hash[Integer, Array[User]]
  def self.read_file(companies, filename: FILENAME)
    ChallengeLogger.logger.info "Reading users file '#{filename}'."
    file = File.read(filename)
    data = JSON.parse(file)
    users = data.map do |user_data|
      user_data['company'] = companies.fetch(user_data.delete('company_id').to_i, nil)
      User.new(user_data)
    end
    users.group_by { |user| user.company&.id }
  end

  private

  def validate!
    validate_presence!
    validate_booleans!
    validate_tokens!
  end

  def validate_booleans!
    raise ArgumentError, 'email_status must be a boolean (true or false)' unless [true, false].include?(email_status)
    raise ArgumentError, 'active_status must be a boolean (true or false)' unless [true, false].include?(active_status)
  end

  def validate_tokens!
    raise ArgumentError, 'tokens must be a number' unless tokens.is_a?(Numeric)
  end

  def validate_presence!
    required_attributes = %i[id first_name last_name email email_status active_status tokens]
    missing_attributes = required_attributes.select do |attr|
      send(attr).nil? || (send(attr).respond_to?(:empty?) && send(attr).empty?)
    end
    return if missing_attributes.empty?

    raise ArgumentError, "Missing required attributes: #{missing_attributes.join(', ')}"
  end

  def top_up_tokens
    # defensive programming: this should not happen due to earlier checks, but still good practice to double check :)
    if company.nil?
      ChallengeLogger.logger.warn("User #{id} has no Company assigned.")
      return 0
    end
    return 0 unless active_status == true

    top_up_amount = company.top_up.clamp(0, Float::INFINITY)
    @tokens += top_up_amount
    top_up_amount
  end
end

# The Company class represents a business entity with attributes such as id, name, top_up amount, and email_status.
# It ensures all attributes are present and valid upon initialization. The class provides functionality to process
# a collection of users by handling their token top-ups and managing email notifications based on both user and
# company email statuses.
class Company
  FILENAME = 'companies.json'

  attr_accessor :id, :name, :top_up, :email_status

  def initialize(attrs = {})
    @id = attrs['id']
    @name = attrs['name']
    @top_up = attrs['top_up']
    @email_status = attrs['email_status']
    validate!
  end

  # Sorts users by last name, partitions them based on email eligibility, and processes their token top-ups.
  # Prints company details and the total accumulated top-up amount to the provided output file.
  # It relies on a StringIO to collect output from this and sub methods, and print it to the output file conditionally.
  def process_users(users, output_file)
    buffer = ::StringIO.new

    buffer.puts ''
    buffer.puts "Company Id: #{id}"
    buffer.puts "Company Name: #{name}"

    sorted_users = users.sort_by(&:last_name)
    emailed_users, not_emailed_users = sorted_users.partition(&:should_send_email?) # Enumerable#partition() is stable
    accumulated_top_up = 0
    accumulated_top_up += process_user_group(emailed_users, 'Users Emailed', buffer)
    accumulated_top_up += process_user_group(not_emailed_users, 'Users Not Emailed', buffer)

    buffer.puts "Total amount of top ups for #{name}: #{accumulated_top_up}"
    if accumulated_top_up.positive?
      output_file.puts buffer.string
    else
      ChallengeLogger.logger.warn("Company #{name} had no top ups and will not show up in output file.")
    end
  end

  # Reads and parses the 'companies.json' file, creating a hash of Company objects keyed by their id.
  # Raises an ArgumentError if duplicate company IDs are found during processing.
  # @return Hash[Integer, Company]
  def self.read_file(filename: FILENAME)
    ChallengeLogger.logger.info "Reading companies file '#{filename}'."
    file = File.read(filename)
    data = JSON.parse(file)
    companies = {}
    data.each do |company_data|
      company = Company.new(company_data)
      raise ArgumentError, "Duplicate company id found: #{company.id}" if companies.key?(company.id)

      companies[company.id] = company
    end
    companies
  end

  private

  def process_user_group(users, label, output_file)
    output_file.puts "#{label}:"
    users.reduce(0) do |sum, user|
      sum + user.process_top_up(output_file)
    end
  end

  def validate!
    validate_presence!
    raise ArgumentError, 'email_status must be a boolean (true or false)' unless [true, false].include?(email_status)
    raise ArgumentError, 'top_up must be a positive number' unless top_up.is_a?(Numeric) && top_up.positive?
  end

  def validate_presence!
    missing_attributes = []
    %i[id name top_up email_status].each do |attr|
      value = send(attr)
      missing_attributes << attr if value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    return if missing_attributes.empty?

    raise ArgumentError, "Missing required attributes: #{missing_attributes.join(', ')}"
  end
end

# Executes the main challenge by loading companies and their associated users, processing each company's users,
# and writing the results to 'output.txt'.
# Logs the processing progress and handles any errors that occur during execution using ChallengeLogger.
def challenge
  companies = Company.read_file
  grouped_users = User.read_file(companies)

  output_file = File.open('output.txt', 'w')

  sorted_companies = companies.values.sort_by(&:id)
  ChallengeLogger.logger.info "Processing #{sorted_companies.count} companies..."
  sorted_companies.each do |company|
    ChallengeLogger.logger.info "Processing company #{company.id}:#{company.name}"
    company_users = grouped_users.fetch(company.id, [])
    company.process_users(company_users, output_file)
  end
  ChallengeLogger.logger.info 'Done'
rescue StandardError => e
  ChallengeLogger.logger.error "An error occurred: #{e.message}"
end

challenge
