#!/usr/bin/env ruby
# Validate the Supabase Management API secret metadata without displaying values.
require "json"

inventory_path, output_path = ARGV
abort("ERROR: expected inventory and output paths") if inventory_path.nil? || output_path.nil?
File.delete(output_path) if File.file?(output_path)

begin
  rows = JSON.parse(File.read(inventory_path))
rescue JSON::ParserError, Errno::ENOENT
  abort("ERROR: secret inventory response is unavailable or malformed JSON")
end

unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row["name"].is_a?(String) }
  abort("ERROR: secret inventory response is not the expected array of named entries")
end

matches = rows.select { |row| row["name"] == "ADMIN_PROVISION_ALLOWED_ORIGIN" }
if matches.empty?
  abort("ERROR: required ADMIN_PROVISION_ALLOWED_ORIGIN is missing from Core Edge secrets")
elsif matches.length != 1
  abort("ERROR: ADMIN_PROVISION_ALLOWED_ORIGIN has duplicate entries; release blocked")
end

digest = matches.first["value"]
unless digest.is_a?(String) && digest.match?(/\A[a-f0-9]{64}\z/)
  abort("ERROR: trusted origin entry exists but its returned metadata is not a SHA-256 digest")
end
File.open(output_path, File::WRONLY | File::CREAT | File::EXCL, 0600) { |file| file.puts(digest) }
puts("Trusted origin metadata found: exactly one named entry, SHA-256 format verified")
