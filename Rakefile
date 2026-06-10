# frozen_string_literal: true

require "sqlite3"
require "json"
require "net/http"
require "uri"
require "time"
require "fileutils"

KOBO_VOLUME = "/Volumes/KOBOeReader"
KOBO_DB = "#{KOBO_VOLUME}/.kobo/KoboReader.sqlite"
STATE_DIR = File.expand_path("~/.kobo-sync")
STATE_DB = "#{STATE_DIR}/state.db"

def kobo_mounted?
  File.exist?(KOBO_DB)
end

def require_kobo!
  unless kobo_mounted?
    abort "Error: Kobo not mounted. Expected database at #{KOBO_DB}"
  end
end

def state_db
  FileUtils.mkdir_p(STATE_DIR)

  db = SQLite3::Database.new(STATE_DB)
  db.execute <<~SQL
    CREATE TABLE IF NOT EXISTS synced_sessions (
      open_event_id TEXT PRIMARY KEY,
      leave_event_id TEXT,
      book_id INTEGER,
      synced_at TEXT
    )
  SQL
  # Add fallback column if missing (migration)
  columns = db.execute("PRAGMA table_info(synced_sessions)").map { |c| c[1] }
  unless columns.include?("fallback")
    db.execute("ALTER TABLE synced_sessions ADD COLUMN fallback INTEGER DEFAULT 0")
  end
  # Dedup is keyed on leave_event_id (open_event_id is NULL for orphan
  # LeaveContent sessions; SQLite permits multiple NULLs in a TEXT PRIMARY KEY).
  db.execute("CREATE INDEX IF NOT EXISTS idx_synced_leave_event ON synced_sessions(leave_event_id)")

  db.execute <<~SQL
    CREATE TABLE IF NOT EXISTS config (
      key TEXT PRIMARY KEY,
      value TEXT
    )
  SQL
  db
end

def get_config(db, key)
  db.get_first_value("SELECT value FROM config WHERE key = ?", key)
end

def set_config(db, key, value)
  db.execute("INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)", [key, value])
end

def read_kobo_sync_url
  config_file = "#{KOBO_VOLUME}/.kobo/Kobo/Kobo eReader.conf"
  return nil unless File.exist?(config_file)

  content = File.read(config_file)
  if content =~ /api_endpoint=(.+)/
    $1.strip
  end
end

def parse_kobo_sync_url(url)
  return nil unless url

  if url =~ %r{(https?://[^/]+)/api/kobo/([^/\s]+)}
    { base_url: $1, token: $2 }
  end
end

# Extract new (not-yet-synced, >= min_seconds) reading sessions from the Kobo.
#
# A reading session is driven by the LeaveContent event: it alone carries the
# substance (SecondsRead, PagesTurned, end progress/location). The matching
# OpenContent's Metrics are empty `{}` — it only adds start-side detail. So we
# emit a session for every LeaveContent and treat a preceding OpenContent as
# optional enrichment. When there is no OpenContent (e.g. the reader resumed
# from standby without a fresh open event), we derive the start from the leave
# event itself instead of silently dropping a real session.
#
# Dedup key is leave_event_id (the canonical end-of-session record, always
# present). Rows synced under the old scheme also stored leave_event_id, so
# this stays backward-compatible.
def extract_new_sessions(kobo_db, sdb, min_seconds)
  events = kobo_db.execute(<<~SQL)
    SELECT Id, Type, Timestamp, Attributes, Metrics
    FROM AnalyticsEvents
    WHERE Type IN ('OpenContent', 'LeaveContent')
    ORDER BY Timestamp ASC
  SQL

  sessions = []
  open_events = {}

  events.each do |event|
    attrs = JSON.parse(event["Attributes"]) rescue {}
    metrics = JSON.parse(event["Metrics"]) rescue {}
    volumeid = attrs["volumeid"]
    next unless volumeid

    if event["Type"] == "OpenContent"
      # Remember the most recent open for this book; only used to enrich the
      # matching LeaveContent below.
      open_events[volumeid] = event
      next
    end

    # LeaveContent: the authoritative session record.
    leave_event_id = event["Id"]

    already_synced = sdb.get_first_value(
      "SELECT 1 FROM synced_sessions WHERE leave_event_id = ?",
      leave_event_id
    )
    next if already_synced

    duration_seconds = metrics["SecondsRead"] || 0
    end_time = event["Timestamp"]
    end_progress = attrs["progress"].to_f
    end_location = "#{attrs['StartFile']}##{attrs['StartSpan']}"

    open_event = open_events.delete(volumeid)
    if open_event
      open_attrs = JSON.parse(open_event["Attributes"]) rescue {}
      open_event_id = open_event["Id"]
      start_time = open_event["Timestamp"]
      start_progress = open_attrs["progress"].to_f
      start_location = "#{open_attrs['StartFile']}##{open_attrs['StartSpan']}"
    else
      # Orphan LeaveContent: derive start from the leave event. SecondsRead is
      # active reading time; with Kobo's small IdleTime this closely tracks the
      # real start and is accurate enough for day attribution / streaks.
      # Start-side progress/location are unknown, so mirror the end values with
      # a zero delta — conservative: never falsely advances or completes a book.
      open_event_id = nil
      start_time = (Time.parse(end_time).utc - duration_seconds).strftime("%Y-%m-%dT%H:%M:%SZ")
      start_progress = end_progress
      start_location = end_location
    end

    title = kobo_db.get_first_value(
      "SELECT Title FROM content WHERE ContentID = ? AND ContentType = 6",
      volumeid
    )

    sessions << {
      open_event_id: open_event_id,
      leave_event_id: leave_event_id,
      volume_id: volumeid,
      book_id: volumeid.to_i,
      book_title: title || "Unknown",
      start_time: start_time,
      end_time: end_time,
      duration_seconds: duration_seconds,
      start_progress: start_progress,
      end_progress: end_progress,
      progress_delta: end_progress - start_progress,
      start_location: start_location,
      end_location: end_location,
      pages_turned: metrics["PagesTurned"] || 0,
      orphan: open_event.nil?
    }
  end

  skipped = sessions.count { |s| s[:duration_seconds] < min_seconds }
  sessions.reject! { |s| s[:duration_seconds] < min_seconds }
  [sessions, skipped]
end

namespace :kobo do
  desc "Check if Kobo is mounted"
  task :check do
    if kobo_mounted?
      puts "✓ Kobo is mounted at #{KOBO_VOLUME}"

      db = SQLite3::Database.new(KOBO_DB)
      book_count = db.get_first_value("SELECT COUNT(*) FROM content WHERE ContentType = 6")
      puts "  Books: #{book_count}"

      events_count = db.get_first_value("SELECT COUNT(*) FROM AnalyticsEvents")
      puts "  AnalyticsEvents: #{events_count}"
      db.close

      sdb = state_db
      synced = sdb.get_first_value("SELECT COUNT(*) FROM synced_sessions")
      puts "  Already synced sessions: #{synced}"
      sdb.close
    else
      puts "✗ Kobo not mounted at #{KOBO_VOLUME}"
      exit 1
    end
  end

  desc "Install trigger to preserve AnalyticsEvents data"
  task :install_trigger do
    require_kobo!

    db = SQLite3::Database.new(KOBO_DB)

    existing = db.get_first_value(
      "SELECT name FROM sqlite_master WHERE type='trigger' AND name='PreserveAnalyticsEvents'"
    )

    if existing
      puts "✓ Trigger 'PreserveAnalyticsEvents' already installed"
    else
      puts "Installing trigger to preserve AnalyticsEvents..."

      db.execute <<~SQL
        CREATE TRIGGER PreserveAnalyticsEvents
        BEFORE DELETE ON AnalyticsEvents
        BEGIN
            SELECT RAISE(IGNORE);
        END;
      SQL

      puts "✓ Trigger installed successfully"
    end

    db.close
  end

  desc "Remove the PreserveAnalyticsEvents trigger"
  task :remove_trigger do
    require_kobo!

    db = SQLite3::Database.new(KOBO_DB)

    existing = db.get_first_value(
      "SELECT name FROM sqlite_master WHERE type='trigger' AND name='PreserveAnalyticsEvents'"
    )

    if existing
      db.execute("DROP TRIGGER PreserveAnalyticsEvents")
      puts "✓ Trigger removed"
    else
      puts "Trigger was not installed"
    end

    db.close
  end

  desc "Show AnalyticsEvents table schema"
  task :schema do
    require_kobo!

    db = SQLite3::Database.new(KOBO_DB)

    puts "=== AnalyticsEvents Schema ==="
    schema = db.get_first_value("SELECT sql FROM sqlite_master WHERE type='table' AND name='AnalyticsEvents'")
    puts schema
    puts

    puts "=== Sample Data (last 5 events) ==="
    db.results_as_hash = true
    rows = db.execute("SELECT * FROM AnalyticsEvents ORDER BY rowid DESC LIMIT 5")
    rows.each do |row|
      puts JSON.pretty_generate(row)
      puts "---"
    end

    puts
    puts "=== Event Types ==="
    types = db.execute("SELECT DISTINCT Type, COUNT(*) as count FROM AnalyticsEvents GROUP BY Type ORDER BY count DESC")
    types.each do |row|
      puts "  #{row['Type']}: #{row['count']} events"
    end

    db.close
  end

  desc "Show installed triggers"
  task :triggers do
    require_kobo!

    db = SQLite3::Database.new(KOBO_DB)

    triggers = db.execute("SELECT name, sql FROM sqlite_master WHERE type='trigger'")

    if triggers.empty?
      puts "No triggers installed"
    else
      puts "=== Installed Triggers ==="
      triggers.each do |name, sql|
        puts "#{name}:"
        puts "  #{sql}"
        puts
      end
    end

    db.close
  end
end

namespace :grimmory do
  desc "Configure Grimmory API connection"
  task :configure do
    sdb = state_db

    current_url = get_config(sdb, "booklore_url")
    current_username = get_config(sdb, "username")
    current_password = get_config(sdb, "password")

    # Try to detect URL from Kobo config if no current value
    detected_url = nil
    if kobo_mounted?
      kobo_url = read_kobo_sync_url
      parsed = parse_kobo_sync_url(kobo_url)
      detected_url = parsed[:base_url] if parsed
    end

    default_url = current_url || detected_url
    if default_url
      print "Grimmory URL [#{default_url}]: "
      url_input = $stdin.gets.chomp
      set_config(sdb, "booklore_url", url_input.empty? ? default_url : url_input)
    else
      print "Grimmory URL (e.g., https://grimmory.example.com): "
      set_config(sdb, "booklore_url", $stdin.gets.chomp)
    end

    print "Username#{current_username ? " [#{current_username}]" : ""}: "
    username_input = $stdin.gets.chomp
    set_config(sdb, "username", username_input.empty? && current_username ? current_username : username_input)

    print "Password#{current_password ? " [unchanged]" : ""}: "
    system("stty -echo")
    password_input = $stdin.gets.chomp
    system("stty echo")
    puts
    set_config(sdb, "password", password_input.empty? && current_password ? current_password : password_input)

    current_min = get_config(sdb, "min_session_seconds") || "60"
    print "Minimum session duration in seconds [#{current_min}]: "
    min_input = $stdin.gets.chomp
    set_config(sdb, "min_session_seconds", min_input.empty? ? current_min : min_input)

    current_default_book = get_config(sdb, "default_book_id")
    print "Default book ID for unknown books#{current_default_book ? " [#{current_default_book}]" : " (leave blank to skip)"}: "
    book_input = $stdin.gets.chomp
    if book_input.empty?
      set_config(sdb, "default_book_id", current_default_book) if current_default_book
    else
      set_config(sdb, "default_book_id", book_input)
    end

    puts "✓ Configuration saved to #{STATE_DB}"
    sdb.close
  end

  desc "Show current configuration"
  task :config do
    sdb = state_db
    url = get_config(sdb, "booklore_url")
    username = get_config(sdb, "username")
    password = get_config(sdb, "password")

    min_session = get_config(sdb, "min_session_seconds")
    default_book = get_config(sdb, "default_book_id")

    puts "Grimmory URL: #{url || '(not set)'}"
    puts "Username: #{username || '(not set)'}"
    puts "Password: #{password ? '(set)' : '(not set)'}"
    puts "Min session seconds: #{min_session || '60 (default)'}"
    puts "Default book ID: #{default_book || '(not set)'}"
    sdb.close
  end
end

namespace :sync do
  desc "Show reading sessions that would be synced (dry run)"
  task :preview do
    require_kobo!

    kobo_db = SQLite3::Database.new(KOBO_DB)
    kobo_db.results_as_hash = true
    sdb = state_db
    min_seconds = (get_config(sdb, "min_session_seconds") || "60").to_i

    sessions, skipped = extract_new_sessions(kobo_db, sdb, min_seconds)

    if sessions.empty?
      puts "No new reading sessions to sync"
    else
      puts "=== Reading Sessions to Sync (#{sessions.size}) ==="
      sessions.each do |s|
        puts "  \"#{s[:book_title]}\"#{s[:orphan] ? ' (start derived — no open event)' : ''}"
        puts "    Time: #{s[:start_time]} → #{s[:end_time]}"
        puts "    Duration: #{s[:duration_seconds]}s (#{(s[:duration_seconds] / 60.0).round(1)} min)"
        puts "    Progress: #{s[:start_progress]}% → #{s[:end_progress]}% (#{s[:progress_delta] >= 0 ? '+' : ''}#{s[:progress_delta].round(1)}%)"
        puts "    Pages turned: #{s[:pages_turned]}"
        puts
      end
    end

    puts "Skipped #{skipped} short session(s) (< #{min_seconds}s)" if skipped > 0

    kobo_db.close
    sdb.close
  end

  desc "Sync reading sessions to Grimmory"
  task :run do
    require_kobo!

    sdb = state_db
    url = get_config(sdb, "booklore_url")
    username = get_config(sdb, "username")
    password = get_config(sdb, "password")

    unless url && username && password
      abort "Error: Grimmory not configured. Run: rake grimmory:configure"
    end

    min_seconds = (get_config(sdb, "min_session_seconds") || "60").to_i
    default_book_id = get_config(sdb, "default_book_id")

    kobo_db = SQLite3::Database.new(KOBO_DB)
    kobo_db.results_as_hash = true

    # Get JWT token
    puts "Authenticating with Grimmory..."
    auth_uri = URI.join(url, "/api/v1/auth/login")
    http = Net::HTTP.new(auth_uri.host, auth_uri.port)
    http.use_ssl = auth_uri.scheme == "https"

    auth_request = Net::HTTP::Post.new(auth_uri)
    auth_request["Content-Type"] = "application/json"
    auth_request.body = { username: username, password: password }.to_json

    auth_response = http.request(auth_request)
    unless auth_response.is_a?(Net::HTTPSuccess)
      abort "Error: Authentication failed (#{auth_response.code}): #{auth_response.body}"
    end

    auth_data = JSON.parse(auth_response.body)
    token = auth_data["accessToken"]
    puts "✓ Authenticated"

    sessions, skipped = extract_new_sessions(kobo_db, sdb, min_seconds)
    puts "Skipped #{skipped} short session(s) (< #{min_seconds}s)" if skipped > 0

    if sessions.empty?
      puts "No new reading sessions to sync"
    else
      puts "Syncing #{sessions.size} reading session(s)..."

      sessions.each do |s|
        progress_delta = s[:progress_delta]

        payload = {
          bookId: s[:book_id],
          bookType: "EPUB",
          startTime: s[:start_time],
          endTime: s[:end_time],
          durationSeconds: s[:duration_seconds],
          startProgress: s[:start_progress],
          endProgress: s[:end_progress],
          progressDelta: progress_delta,
          startLocation: s[:start_location],
          endLocation: s[:end_location]
        }

        api_uri = URI.join(url, "/api/v1/reading-sessions")
        api_http = Net::HTTP.new(api_uri.host, api_uri.port)
        api_http.use_ssl = api_uri.scheme == "https"

        request = Net::HTTP::Post.new(api_uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{token}"
        request.body = payload.to_json

        response = api_http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          sdb.execute(
            "INSERT INTO synced_sessions (open_event_id, leave_event_id, book_id, synced_at) VALUES (?, ?, ?, ?)",
            [s[:open_event_id], s[:leave_event_id], s[:book_id], Time.now.utc.iso8601]
          )
          puts "  ✓ Book #{s[:book_id]}: #{s[:duration_seconds]}s synced"
        elsif response.code == "404"
          if default_book_id
            # Retry with default book, zero out progress to avoid marking it as completed
            fallback_payload = payload.merge(
              bookId: default_book_id.to_i,
              startProgress: 0,
              endProgress: 0,
              progressDelta: 0
            )
            request2 = Net::HTTP::Post.new(api_uri)
            request2["Content-Type"] = "application/json"
            request2["Authorization"] = "Bearer #{token}"
            request2.body = fallback_payload.to_json

            retry_response = api_http.request(request2)
            if retry_response.is_a?(Net::HTTPSuccess)
              sdb.execute(
                "INSERT INTO synced_sessions (open_event_id, leave_event_id, book_id, synced_at, fallback) VALUES (?, ?, ?, ?, 1)",
                [s[:open_event_id], s[:leave_event_id], s[:book_id], Time.now.utc.iso8601]
              )
              puts "  ✓ \"#{s[:book_title]}\" → default book #{default_book_id}: #{s[:duration_seconds]}s synced"
            else
              puts "  ✗ \"#{s[:book_title]}\" → default book #{default_book_id}: Failed (#{retry_response.code})"
            end
          else
            # No default book — mark as synced so we don't retry
            sdb.execute(
              "INSERT INTO synced_sessions (open_event_id, leave_event_id, book_id, synced_at, fallback) VALUES (?, ?, ?, ?, 1)",
              [s[:open_event_id], s[:leave_event_id], s[:book_id], Time.now.utc.iso8601]
            )
            puts "  ⊘ \"#{s[:book_title]}\" skipped (not in Grimmory)"
          end
        else
          puts "  ✗ Book #{s[:book_id]}: Failed (#{response.code}): #{response.body}"
        end
      end
    end

    kobo_db.close
    sdb.close
    puts "Done"
  end

  desc "Reset sync state (mark all sessions as not synced)"
  task :reset do
    sdb = state_db
    count = sdb.get_first_value("SELECT COUNT(*) FROM synced_sessions")
    sdb.execute("DELETE FROM synced_sessions")
    puts "✓ Reset #{count} synced session(s)"
    sdb.close
  end

  desc "Reset unknown/fallback sessions so they sync again"
  task :reset_unknowns do
    sdb = state_db
    count = sdb.get_first_value("SELECT COUNT(*) FROM synced_sessions WHERE fallback = 1")

    if count == 0
      puts "No fallback sessions to reset"
      sdb.close
      next
    end

    puts "This will reset #{count} fallback session(s)."
    puts "To avoid duplicates, delete the catch-all book in Grimmory first, then re-upload it."
    print "Continue? [y/N]: "
    answer = $stdin.gets.chomp.downcase

    if answer == "y"
      sdb.execute("DELETE FROM synced_sessions WHERE fallback = 1")
      puts "✓ Reset #{count} fallback session(s) — will re-sync on next run"
    else
      puts "Aborted"
    end

    sdb.close
  end

  desc "Show sync statistics"
  task :stats do
    sdb = state_db
    sdb.results_as_hash = true

    total = sdb.get_first_value("SELECT COUNT(*) FROM synced_sessions")
    puts "Total synced sessions: #{total}"

    if total > 0
      puts "\nBy book:"
      rows = sdb.execute(<<~SQL)
        SELECT book_id, COUNT(*) as sessions, MIN(synced_at) as first_sync, MAX(synced_at) as last_sync
        FROM synced_sessions
        GROUP BY book_id
        ORDER BY sessions DESC
      SQL
      rows.each do |r|
        puts "  Book #{r['book_id']}: #{r['sessions']} session(s)"
      end
    end

    sdb.close
  end
end

LAUNCHD_LABEL = "com.kobo-sync"
LAUNCHD_PLIST = File.expand_path("~/Library/LaunchAgents/#{LAUNCHD_LABEL}.plist")
SUPPORT_DIR = File.expand_path("support", __dir__)

namespace :automation do
  desc "Install launchd agent to auto-sync when Kobo is mounted"
  task :install do
    sdb = state_db
    url = get_config(sdb, "booklore_url")
    username = get_config(sdb, "username")
    sdb.close

    unless url && username
      abort "Error: Configure Grimmory first: rake grimmory:configure"
    end

    FileUtils.mkdir_p(STATE_DIR)
    FileUtils.mkdir_p(File.dirname(LAUNCHD_PLIST))

    # Install the sync script
    script_source = File.join(SUPPORT_DIR, "kobo-sync-on-mount.sh")
    script_dest = File.join(STATE_DIR, "kobo-sync-on-mount.sh")

    script_content = File.read(script_source)
    script_content.gsub!("{{KOBO_SYNC_DIR}}", __dir__)
    File.write(script_dest, script_content)
    File.chmod(0755, script_dest)

    # Install the plist
    plist_source = File.join(SUPPORT_DIR, "com.kobo-sync.plist")
    plist_content = File.read(plist_source)
    plist_content.gsub!("{{SCRIPT_PATH}}", script_dest)
    plist_content.gsub!("{{HOME}}", ENV["HOME"])
    File.write(LAUNCHD_PLIST, plist_content)

    # Unload if already loaded, then load
    system("launchctl unload #{LAUNCHD_PLIST} 2>/dev/null")
    if system("launchctl load #{LAUNCHD_PLIST}")
      puts "✓ Automation installed"
      puts "  Plist: #{LAUNCHD_PLIST}"
      puts "  Script: #{script_dest}"
      puts "  Log: #{STATE_DIR}/sync.log"
      puts ""
      puts "Kobo sync will now run automatically when you mount your Kobo."
    else
      abort "Error: Failed to load launchd agent"
    end
  end

  desc "Uninstall the launchd agent"
  task :uninstall do
    if File.exist?(LAUNCHD_PLIST)
      system("launchctl unload #{LAUNCHD_PLIST} 2>/dev/null")
      File.delete(LAUNCHD_PLIST)
      puts "✓ Automation uninstalled"
    else
      puts "Automation was not installed"
    end

    script_path = File.join(STATE_DIR, "kobo-sync-on-mount.sh")
    File.delete(script_path) if File.exist?(script_path)
    # Clean up old name if exists
    old_script = File.join(STATE_DIR, "sync-on-mount.sh")
    File.delete(old_script) if File.exist?(old_script)
  end

  desc "Check automation status"
  task :status do
    if File.exist?(LAUNCHD_PLIST)
      loaded = `launchctl list 2>/dev/null | grep #{LAUNCHD_LABEL}`.strip
      if loaded.empty?
        puts "Automation: installed but not loaded"
        puts "  Run: launchctl load #{LAUNCHD_PLIST}"
      else
        puts "✓ Automation: installed and running"
      end
      puts "  Plist: #{LAUNCHD_PLIST}"
      puts "  Log: #{STATE_DIR}/sync.log"
    else
      puts "Automation: not installed"
      puts "  Run: rake automation:install"
    end
  end

  desc "Show automation logs"
  task :logs do
    log_file = "#{STATE_DIR}/sync.log"
    if File.exist?(log_file)
      puts File.read(log_file)
    else
      puts "No logs yet"
    end
  end
end

namespace :kobo do
  desc "Set up Kobo for syncing (install trigger, check analytics)"
  task :setup do
    require_kobo!

    db = SQLite3::Database.new(KOBO_DB)

    # 1. Install preservation trigger
    existing = db.get_first_value(
      "SELECT name FROM sqlite_master WHERE type='trigger' AND name='PreserveAnalyticsEvents'"
    )

    if existing
      puts "✓ Trigger 'PreserveAnalyticsEvents' already installed"
    else
      puts "Installing trigger to preserve AnalyticsEvents..."
      db.execute <<~SQL
        CREATE TRIGGER PreserveAnalyticsEvents
        BEFORE DELETE ON AnalyticsEvents
        BEGIN
            SELECT RAISE(IGNORE);
        END;
      SQL
      puts "✓ Trigger installed successfully"
    end

    db.close

    # 2. Check if analytics will be gathered
    user_db = SQLite3::Database.new(KOBO_DB)
    privacy = user_db.get_first_value("SELECT PrivacyPermissions FROM user")
    user_db.close

    if privacy && privacy.bytesize > 4
      puts "✓ Analytics enabled (PrivacyPermissions is set)"
    else
      puts "✗ Analytics disabled (PrivacyPermissions is empty)"
      puts "  No reading events will be recorded."
      puts "  Temporarily set api_endpoint to https://storeapi.kobo.com,"
      puts "  sync with Kobo's servers, accept the privacy consent,"
      puts "  then restore the Grimmory endpoint."
    end
  end
end

desc "Default: check Kobo status"
task default: "kobo:check"
