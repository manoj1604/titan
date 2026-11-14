require "json"
require "rbconfig"

class App
  def call(env)
    case env["PATH_INFO"]
    when "/health"
      body = { ok: true, platform: "#{RbConfig::CONFIG['host_os']} #{RbConfig::CONFIG['host_cpu']}", ruby: RUBY_VERSION }
      [200, { "content-type" => "application/json" }, [body.to_json]]
    else
      [404, { "content-type" => "text/plain" }, ["not found"]]
    end
  end
end
