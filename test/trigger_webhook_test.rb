# frozen_string_literal: true

# Hermetic test for step 1 of bin/compile: the Harness webhook call.
# curl is stubbed via PATH, so no network is used.
#
#   ruby test/trigger_webhook_test.rb
#   COMPILE=/path/to/other/bin/compile ruby test/trigger_webhook_test.rb

require "fileutils"
require "minitest"
require "open3"
require "tmpdir"

class TriggerWebhookTest < Minitest::Test
  COMPILE = ENV.fetch("COMPILE", File.expand_path("../bin/compile", __dir__))

  # HEAD for finished.txt -> 404 (curl -f exits 22); POST -> mode from STUB_WEBHOOK.
  CURL_STUB = <<~SH
    #!/usr/bin/env bash
    case " $* " in
      *" -I "*) exit 22 ;;
    esac
    out=""
    while [ $# -gt 0 ]; do
      [ "$1" = "-o" ] && out=$2
      shift
    done
    case "$STUB_WEBHOOK" in
      ok) printf '{"status":"SUCCESS"}' > "$out"; printf 200 ;;
      error) printf '{"status":"ERROR","message":"Invalid trigger"}' > "$out"; printf 500 ;;
      unreachable) echo "curl: (6) Could not resolve host: app.harness.io" >&2; printf 000; exit 6 ;;
    esac
  SH

  ENV_VARS = {
    "CDN_HOST" => "cdn.example.test",
    "RAILS_ENV" => "staging",
    "HARNESS_WEBHOOK_BASE_URL" => "https://app.harness.io/gateway/pipeline/api/webhook/custom/v2",
    "HARNESS_ACCOUNT_IDENTIFIER" => "acc",
    "HARNESS_ORG_IDENTIFIER" => "org",
    "HARNESS_PROJECT_IDENTIFIER" => "proj",
    "HARNESS_PIPELINE_IDENTIFIER" => "pipe",
    "HARNESS_TRIGGER_IDENTIFIER" => "trig"
  }.freeze

  def run_step1(mode)
    Dir.mktmpdir do |dir|
      buildpack = File.join(dir, "buildpack")
      FileUtils.mkdir_p(File.join(buildpack, "bin"))
      FileUtils.cp(COMPILE, File.join(buildpack, "bin", "compile"))
      stub_bin = File.join(dir, "stub")
      FileUtils.mkdir_p(stub_bin)
      File.write(File.join(stub_bin, "curl"), CURL_STUB)
      File.chmod(0o755, File.join(stub_bin, "curl"))
      env_dir = File.join(dir, "env")
      FileUtils.mkdir_p(env_dir)
      ENV_VARS.each { |name, value| File.write(File.join(env_dir, name), value) }
      build_dir = File.join(dir, "build")
      FileUtils.mkdir_p(build_dir)

      env = {
        "PATH" => "#{stub_bin}:#{ENV.fetch("PATH")}",
        "STUB_WEBHOOK" => mode,
        "SOURCE_VERSION" => "abc123",
        "CURRENT_BUILDPACK_STEP" => nil
      }
      out, status = Open3.capture2e(env, "bash", File.join(buildpack, "bin", "compile"),
                                    build_dir, File.join(dir, "cache"), env_dir, chdir: dir)
      [out, status.exitstatus]
    end
  end

  def test_success_continues_step1
    out, code = run_step1("ok")

    assert_equal 0, code, out
    assert_includes out, "Webhook triggered successfully"
    assert_includes out, "Step 1 finished"
  end

  def test_http_error_fails_at_once_with_status_and_body
    out, code = run_step1("error")

    assert_equal 1, code, out
    assert_includes out, "HTTP status code: 500"
    assert_includes out, "Invalid trigger"
    refute_includes out, "Step 1 finished"
  end

  def test_curl_failure_fails_at_once_with_reason
    out, code = run_step1("unreachable")

    assert_equal 1, code, out
    assert_includes out, "curl exit code: 6"
    assert_includes out, "Could not resolve host"
    refute_includes out, "Step 1 finished"
  end
end

Minitest.autorun if $PROGRAM_NAME == __FILE__
