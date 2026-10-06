# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "fixwire"
require "minitest/autorun"
require "zlib"
require "json"

# A fake Fixwire behind the SDK's transport: keeps each request's path, headers and decoded body.
class FakeIngest
  DSN = "http://publickey@ingest.test"

  attr_reader :received
  attr_accessor :answer

  def initialize
    @received = []
    @lock = Mutex.new
    @answer = ->(_n, _path) { [200, {}] }
  end

  def send_request(url, body, headers)
    json = headers["Content-Encoding"] == "gzip" ? Zlib.gunzip(body) : body
    path = URI.decode_www_form_component(URI(url).path)
    n = @lock.synchronize do
      @received << { path: path, headers: headers, body: JSON.parse(json) }
      @received.size - 1
    end
    answer.call(n, path)
  end

  def requests(path = nil) = @lock.synchronize { @received.select { |r| path.nil? || r[:path] == path } }

  # Starts the SDK with this transport and makes its hub current.
  def init(**)
    Fixwire.init(dsn: DSN, service_name: "shop", project_root: File.expand_path("..", __dir__), transport: self,
                 auto_session_tracking: false, breadcrumbs_logger: false, trace_net_http: false, **)
  end

  def log_records(path = "/v1/logs")
    requests(path).flat_map { |r| r[:body]["resourceLogs"].flat_map { |rl| rl["scopeLogs"].flat_map { |sl| sl["logRecords"] } } }
  end

  def spans
    requests("/v1/traces").flat_map do |r|
      r[:body]["resourceSpans"].flat_map do |rs|
        rs["scopeSpans"].flat_map do |ss|
          ss["spans"]
        end
      end
    end
  end

  def self.kv(list) = (list || []).to_h { |kv| [kv["key"], value(kv["value"])] }

  def self.value(v)
    if v.key?("stringValue") then v["stringValue"]
    elsif v.key?("boolValue") then v["boolValue"]
    elsif v.key?("intValue") then v["intValue"].to_i
    elsif v.key?("doubleValue") then v["doubleValue"].to_f
    elsif v.key?("arrayValue") then (v["arrayValue"]["values"] || []).map { |x| value(x) }
    elsif v.key?("kvlistValue") then kv(v["kvlistValue"]["values"])
    end
  end

  def self.resource(request)
    key = request[:body].key?("resourceLogs") ? "resourceLogs" : "resourceSpans"
    kv(request[:body][key][0]["resource"]["attributes"])
  end
end

module FixwireTestCase
  def setup
    super
    Fixwire::Hub.main = nil
    Fixwire::Hub.current = nil
    @ingest = FakeIngest.new
  end

  def attrs(record) = FakeIngest.kv(record["attributes"])
end
