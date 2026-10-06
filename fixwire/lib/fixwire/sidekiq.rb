# frozen_string_literal: true

require "fixwire"
require "sidekiq"

module Fixwire
  # Sidekiq (7 and later): a job carries the trace of the code that pushed it; a job's run is a
  # span that continues that trace, in a scope of its own (the queue as a tag, the job as
  # context), and an exception it raises is a crash, with the job (whether Sidekiq retries it is a
  # tag).
  #
  #   require "fixwire/sidekiq" # after Fixwire.init; Rails apps: in config/initializers/fixwire.rb
  module Sidekiq
    # In the processes that push jobs.
    class ClientMiddleware
      include ::Sidekiq::ClientMiddleware

      def call(_job_class, job, _queue, _redis_pool)
        span = Hub.current.span
        if span && !job.key?("fixwire")
          job["fixwire"] = { "traceparent" => span.traceparent, "tracestate" => span.tracestate, "baggage" => span.baggage }.compact
        end
        yield
      end
    end

    # In the processes that run them.
    class ServerMiddleware
      include ::Sidekiq::ServerMiddleware

      def call(_job_instance, job, queue)
        hub = Hub.current
        return yield unless hub.enabled?

        name = (job["wrapped"] || job["class"]).to_s # an Active Job's own class
        trace = job["fixwire"] || {}
        hub.with_scope do |scope|
          scope.set_tag("queue", queue).set_transaction(name)
               .set_context("job", { "class" => name, "jid" => job["jid"], "retry_count" => job["retry_count"] }.compact)
          attributes = { "messaging.system" => "sidekiq", "messaging.destination.name" => queue, "messaging.message.id" => job["jid"] }
          span = hub.continue_trace(trace["traceparent"], trace["tracestate"], trace["baggage"], name, op: "queue.process",
                                                                                                       attributes: attributes)
          begin
            yield
          rescue Exception => e # rubocop:disable Lint/RescueException -- reported, then raised on
            unless hub.client.captured?(e)
              scope.set_tag("sidekiq.retry", retries?(job) ? "yes" : "no")
              hub.capture_exception(e, mechanism: "sidekiq", handled: false)
            end
            span.set_error(e)
            raise
          ensure
            span.finish
          end
        end
      end

      private

      def retries?(job)
        retry_count = job["retry_count"]
        allowed = job["retry"] == true ? 25 : job["retry"].to_i
        allowed.positive? && (retry_count.nil? || retry_count + 1 < allowed)
      end
    end

    def self.install
      ::Sidekiq.configure_server do |config|
        config.server_middleware { |chain| chain.add(ServerMiddleware) unless chain.exists?(ServerMiddleware) }
        config.client_middleware { |chain| chain.add(ClientMiddleware) unless chain.exists?(ClientMiddleware) }
      end
      ::Sidekiq.configure_client do |config|
        config.client_middleware { |chain| chain.add(ClientMiddleware) unless chain.exists?(ClientMiddleware) }
      end
    end
  end
end

Fixwire::Sidekiq.install
