# frozen_string_literal: true

# A script that ends one way or another, run by ProcessTest: ruby script.rb <scenario> (FIXWIRE_DSN set).

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "fixwire"
require "rbconfig"

Fixwire.init(release: "shop@1.0.0", project_root: File.expand_path("../..", __dir__), auto_session_tracking: false)
Fixwire.add_breadcrumb(category: "script", message: "started")

def charge_card(amount)
  raise ArgumentError, "amount #{amount} exceeds the limit"
end

case ARGV[0]
when "uncaught" then charge_card(500)
when "exit" then exit 1
when "interrupt" then raise Interrupt
when "fork"
  Fixwire.capture_message("from the parent")
  if Process.respond_to?(:fork)
    pid = fork do
      Fixwire.capture_message("from the child") # the parent's worker thread is gone here
    end
    Process.wait(pid)
  else
    # Windows has no fork: the child is a process of its own, as Windows starts them.
    system(RbConfig.ruby, __FILE__, "child", exception: true)
  end
when "forked-worker"
  Fixwire.init(release: "shop@1.0.0", project_root: File.expand_path("../..", __dir__))
  Fixwire::ServerRequest.start(Fixwire.hub, "GET", "http://shop/", {}).finish(200)
  pid = fork do
    worker = Thread.list.any? { |t| t.name == "fixwire-worker" && t.alive? }
    exit!(worker && Fixwire.client.sessions.empty? ? 0 : 3)
  end
  exit(Process.wait2(pid).last.exitstatus)
when "child" then Fixwire.capture_message("from the child")
when "message" then Fixwire.capture_message("nightly report sent")
end
