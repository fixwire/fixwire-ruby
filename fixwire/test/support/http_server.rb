# frozen_string_literal: true

require "socket"
require "zlib"
require "json"

# A small HTTP/1.1 server on a free local port, for tests: keeps each request (method, path,
# headers, body; gzip undone) and answers with what the handler returns.
class TestHTTPServer
  attr_reader :port, :requests

  def initialize(&handler)
    @handler = handler || ->(_request) { [200, {}, "{}"] }
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = Queue.new
    @thread = Thread.new { loop { serve(@server.accept) } }
    @thread.report_on_exception = false
  end

  def url = "http://127.0.0.1:#{port}"

  # The requests received so far, waiting up to timeout seconds for at least count of them.
  def received(count = 1, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.02 while @requests.size < count && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    Array.new(@requests.size) { @requests.pop }
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve(socket)
    line = socket.gets.to_s
    method, path = line.split
    headers = {}
    while (header = socket.gets) && header != "\r\n"
      name, value = header.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = socket.read(headers["content-length"].to_i).to_s
    body = Zlib.gunzip(body) if headers["content-encoding"] == "gzip"
    request = { method: method, path: path, headers: headers, body: body }
    @requests << request
    status, answer_headers, answer = @handler.call(request)
    socket.write("HTTP/1.1 #{status} OK\r\nContent-Length: #{answer.bytesize}\r\nConnection: close\r\n")
    answer_headers.each { |k, v| socket.write("#{k}: #{v}\r\n") }
    socket.write("\r\n#{answer}")
  rescue StandardError
    nil
  ensure
    socket&.close
  end
end
