# frozen_string_literal: true

require "sqlite3"
require "json"
require "net/http"
require "uri"
require "time"
require "fileutils"

# Supported platforms: macOS, Linux. All OS-specific logic uses "if mac? ... elsif linux?".
def platform
  @platform ||= Gem::Platform.local.os
end

def mac?
  platform == "darwin"
end

def linux?
  platform == "linux"
end

def ensure_supported_os!
  return if %w[darwin linux].include?(platform)
  abort "Unsupported OS. This project supports macOS and Linux only. (Detected: #{RUBY_PLATFORM})"
end

# State directory: ~/.kobo-sync on macOS, XDG on Linux
def state_dir
  ensure_supported_os!
  if mac?
    File.expand_path("~/.kobo-sync")
  elsif linux?
    base = ENV["XDG_CONFIG_HOME"]
    base = File.expand_path("~/.config") if base.nil? || base.empty?
    File.join(base, "kobo-sync")
  end
end

STATE_DIR = state_dir
STATE_DB = "#{STATE_DIR}/state.db"

def default_kobo_volume_candidates
  if mac?
    ["/Volumes/KOBOeReader"]
  elsif linux?
    user = ENV["USER"] || ENV["LOGNAME"] || "root"
    ["/run/media/#{user}/KOBOeReader", "/media/#{user}/KOBOeReader"]
  end
end

def preferred_kobo_volume
  sdb = state_db
  cfg = get_config(sdb, "kobo_volume")
  sdb.close
  cfg || ENV["KOBO_VOLUME"] || default_kobo_volume_candidates.first
end

def resolve_kobo_volume
  vol = preferred_kobo_volume
  return vol if vol && File.exist?("#{vol}/.kobo/KoboReader.sqlite")
  default_kobo_volume_candidates.each do |path|
    return path if File.exist?("#{path}/.kobo/KoboReader.sqlite")
  end
  nil
end

def kobo_volume
  @kobo_volume ||= resolve_kobo_volume
end

def kobo_db
  kobo_volume && "#{kobo_volume}/.kobo/KoboReader.sqlite"
end

def kobo_mounted?
  !!kobo_volume
end

def require_kobo!
  unless kobo_mounted?
    candidates = default_kobo_volume_candidates.first(3).join(", ")
    abort "Error: Kobo not mounted. Checked: #{candidates} (or set KOBO_VOLUME or run rake kobo:config_volume)"
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
  return nil unless kobo_volume
  config_file = "#{kobo_volume}/.kobo/Kobo/Kobo eReader.conf"
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

namespace :kobo do
  desc "Check if Kobo is mounted"
  task :check do
    if kobo_mounted?
      puts "✓ Kobo is mounted at #{kobo_volume}"

      db = SQLite3::Database.new(kobo_db)
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
      puts "✗ Kobo not mounted. Checked: #{default_kobo_volume_candidates.first(3).join(', ')}"
      exit 1
    end
  end

  desc "Install trigger to preserve AnalyticsEvents data"
  task :install_trigger do
    require_kobo!

    db = SQLite3::Database.new(kobo_db)

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

    db = SQLite3::Database.new(kobo_db)

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

    db = SQLite3::Database.new(kobo_db)

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

    db = SQLite3::Database.new(kobo_db)

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

  desc "Set Kobo mount path (Linux). On macOS the default /Volumes/KOBOeReader is used."
  task :config_volume do
    if mac?
      puts "On macOS the default /Volumes/KOBOeReader is used."
      puts "Set KOBO_VOLUME to override."
    elsif linux?
      sdb = state_db
      current = get_config(sdb, "kobo_volume")
      sdb.close

      if current
        puts "Current Kobo mount path: #{current}"
        print "Change it? [y/N]: "
        answer = $stdin.gets.chomp.downcase
        unless answer == "y"
          next
        end
      end

      default_path = default_kobo_volume_candidates.first
      detected = default_kobo_volume_candidates.find { |p| File.exist?("#{p}/.kobo/KoboReader.sqlite") }
      unless detected
        dirs = (Dir["/media/#{user}/*"] rescue []) + (Dir["/run/media/#{user}/*"] rescue [])
        detected = dirs.find { |d| File.directory?(d) && File.exist?("#{d}/.kobo/KoboReader.sqlite") }
      end

      if detected
        puts "Detected Kobo at: #{detected}"
        print "Use this path? [Y/n]: "
        answer = $stdin.gets.chomp.downcase
        if answer.empty? || answer == "y"
          path = detected
        else
          puts "Default suggestion: #{default_path}"
          print "Enter Kobo mount path (or press Enter for default): "
          path = $stdin.gets.chomp.strip
          path = default_path if path.empty?
        end
      else
        puts "Kobo not detected at common mount points."
        puts "Default: #{default_path}"
        print "Enter Kobo mount path (or press Enter for default): "
        path = $stdin.gets.chomp.strip
        path = default_path if path.empty?
      end

      sdb = state_db
      set_config(sdb, "kobo_volume", path)
      sdb.close
      @kobo_volume = nil
      puts "✓ Kobo mount path saved: #{path}"
    end
  end
end

def ensure_kobo_volume_configured_on_linux
  return unless linux?
  sdb = state_db
  configured = get_config(sdb, "kobo_volume")
  sdb.close
  return if configured
  Rake::Task["kobo:config_volume"].invoke
end

namespace :booklore do
  desc "Configure BookLore API connection"
  task :configure do
    ensure_kobo_volume_configured_on_linux

    sdb = state_db

    # Try to read URL from Kobo config
    if kobo_mounted?
      kobo_url = read_kobo_sync_url
      parsed = parse_kobo_sync_url(kobo_url)
      if parsed
        puts "Detected BookLore URL from Kobo: #{parsed[:base_url]}"
        print "Use this URL? [Y/n]: "
        answer = $stdin.gets.chomp.downcase
        if answer.empty? || answer == "y"
          set_config(sdb, "booklore_url", parsed[:base_url])
        else
          print "BookLore URL (e.g., https://booklore.example.com): "
          set_config(sdb, "booklore_url", $stdin.gets.chomp)
        end
      else
        print "BookLore URL (e.g., https://booklore.example.com): "
        set_config(sdb, "booklore_url", $stdin.gets.chomp)
      end
    else
      print "BookLore URL (e.g., https://booklore.example.com): "
      set_config(sdb, "booklore_url", $stdin.gets.chomp)
    end

    print "Username: "
    username = $stdin.gets.chomp
    set_config(sdb, "username", username)

    print "Password: "
    system("stty -echo")
    password = $stdin.gets.chomp
    system("stty echo")
    puts
    set_config(sdb, "password", password)

    puts "✓ Configuration saved to #{STATE_DB}"
    sdb.close
  end

  desc "Show current configuration"
  task :config do
    sdb = state_db
    url = get_config(sdb, "booklore_url")
    username = get_config(sdb, "username")
    password = get_config(sdb, "password")

    puts "BookLore URL: #{url || '(not set)'}"
    puts "Username: #{username || '(not set)'}"
    puts "Password: #{password ? '(set)' : '(not set)'}"
    sdb.close
  end
end

namespace :sync do
  desc "Show reading sessions that would be synced (dry run)"
  task :preview do
    require_kobo!

    kobo_db_conn = SQLite3::Database.new(kobo_db)
    kobo_db_conn.results_as_hash = true
    sdb = state_db

    events = kobo_db_conn.execute(<<~SQL)
      SELECT Id, Type, Timestamp, Attributes, Metrics
      FROM AnalyticsEvents
      WHERE Type IN ('OpenContent', 'LeaveContent')
      ORDER BY Timestamp ASC
    SQL

    sessions = []
    open_events = {}

    events.each do |event|
      attrs = JSON.parse(event["Attributes"])
      metrics = JSON.parse(event["Metrics"]) rescue {}
      volumeid = attrs["volumeid"]

      next unless volumeid

      if event["Type"] == "OpenContent"
        open_events[volumeid] = event
      elsif event["Type"] == "LeaveContent" && open_events[volumeid]
        open_event = open_events.delete(volumeid)

        already_synced = sdb.get_first_value(
          "SELECT 1 FROM synced_sessions WHERE open_event_id = ?",
          open_event["Id"]
        )

        next if already_synced

        open_attrs = JSON.parse(open_event["Attributes"])

        title = kobo_db_conn.get_first_value(
          "SELECT Title FROM content WHERE ContentID = ? AND ContentType = 6",
          volumeid
        )

        sessions << {
          open_event_id: open_event["Id"],
          leave_event_id: event["Id"],
          book_id: volumeid.to_i,
          book_title: title || "Unknown",
          start_time: open_event["Timestamp"],
          end_time: event["Timestamp"],
          duration_seconds: metrics["SecondsRead"] || 0,
          start_progress: open_attrs["progress"].to_f,
          end_progress: attrs["progress"].to_f,
          start_location: "#{open_attrs['StartFile']}##{open_attrs['StartSpan']}",
          end_location: "#{attrs['StartFile']}##{attrs['StartSpan']}",
          pages_turned: metrics["PagesTurned"] || 0
        }
      end
    end

    if sessions.empty?
      puts "No new reading sessions to sync"
    else
      puts "=== Reading Sessions to Sync (#{sessions.size}) ==="
      sessions.each do |s|
        progress_delta = s[:end_progress] - s[:start_progress]
        puts "  \"#{s[:book_title]}\""
        puts "    Time: #{s[:start_time]} → #{s[:end_time]}"
        puts "    Duration: #{s[:duration_seconds]}s (#{(s[:duration_seconds] / 60.0).round(1)} min)"
        puts "    Progress: #{s[:start_progress]}% → #{s[:end_progress]}% (#{progress_delta >= 0 ? '+' : ''}#{progress_delta.round(1)}%)"
        puts "    Pages turned: #{s[:pages_turned]}"
        puts
      end
    end

    kobo_db_conn.close
    sdb.close
  end

  desc "Sync reading sessions to BookLore"
  task :run do
    require_kobo!

    sdb = state_db
    url = get_config(sdb, "booklore_url")
    username = get_config(sdb, "username")
    password = get_config(sdb, "password")

    unless url && username && password
      abort "Error: BookLore not configured. Run: rake booklore:configure"
    end

    kobo_db_conn = SQLite3::Database.new(kobo_db)
    kobo_db_conn.results_as_hash = true

    # Get JWT token
    puts "Authenticating with BookLore..."
    auth_uri = URI("#{url}/api/v1/auth/login")
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

    # Get events and pair them
    events = kobo_db_conn.execute(<<~SQL)
      SELECT Id, Type, Timestamp, Attributes, Metrics
      FROM AnalyticsEvents
      WHERE Type IN ('OpenContent', 'LeaveContent')
      ORDER BY Timestamp ASC
    SQL

    sessions = []
    open_events = {}

    events.each do |event|
      attrs = JSON.parse(event["Attributes"])
      metrics = JSON.parse(event["Metrics"]) rescue {}
      volumeid = attrs["volumeid"]

      next unless volumeid

      if event["Type"] == "OpenContent"
        open_events[volumeid] = event
      elsif event["Type"] == "LeaveContent" && open_events[volumeid]
        open_event = open_events.delete(volumeid)

        already_synced = sdb.get_first_value(
          "SELECT 1 FROM synced_sessions WHERE open_event_id = ?",
          open_event["Id"]
        )

        next if already_synced

        open_attrs = JSON.parse(open_event["Attributes"])

        title = kobo_db_conn.get_first_value(
          "SELECT Title FROM content WHERE ContentID = ? AND ContentType = 6",
          volumeid
        )

        sessions << {
          open_event_id: open_event["Id"],
          leave_event_id: event["Id"],
          volume_id: volumeid,
          book_id: volumeid.to_i,
          book_title: title || "Unknown",
          start_time: open_event["Timestamp"],
          end_time: event["Timestamp"],
          duration_seconds: metrics["SecondsRead"] || 0,
          start_progress: open_attrs["progress"].to_f,
          end_progress: attrs["progress"].to_f,
          start_location: "#{open_attrs['StartFile']}##{open_attrs['StartSpan']}",
          end_location: "#{attrs['StartFile']}##{attrs['StartSpan']}"
        }
      end
    end

    if sessions.empty?
      puts "No new reading sessions to sync"
    else
      puts "Syncing #{sessions.size} reading session(s)..."

      sessions.each do |s|
        progress_delta = s[:end_progress] - s[:start_progress]

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

        api_uri = URI("#{url}/api/v1/reading-sessions")
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
          # Book not in BookLore — mark as synced so we don't retry
          sdb.execute(
            "INSERT INTO synced_sessions (open_event_id, leave_event_id, book_id, synced_at) VALUES (?, ?, ?, ?)",
            [s[:open_event_id], s[:leave_event_id], s[:book_id], Time.now.utc.iso8601]
          )
          puts "  ⊘ \"#{s[:book_title]}\" skipped (not in BookLore)"
        else
          puts "  ✗ Book #{s[:book_id]}: Failed (#{response.code}): #{response.body}"
        end
      end
    end

    kobo_db_conn.close
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

SUPPORT_DIR = File.expand_path("support", __dir__)
LAUNCHD_LABEL = "com.kobo-sync"
LAUNCHD_PLIST = File.expand_path("~/Library/LaunchAgents/#{LAUNCHD_LABEL}.plist")
SYSTEMD_USER_DIR = File.expand_path("~/.config/systemd/user")

namespace :automation do
  desc "Install auto-sync when Kobo is mounted (launchd on macOS, systemd on Linux)"
  task :install do
    sdb = state_db
    url = get_config(sdb, "booklore_url")
    username = get_config(sdb, "username")
    sdb.close

    unless url && username
      abort "Error: Configure BookLore first: rake booklore:configure"
    end

    watch_path = preferred_kobo_volume
    if linux? && (watch_path.nil? || watch_path.empty?)
      abort "Error: Set Kobo mount path first: rake kobo:config_volume"
    end
    watch_path ||= "/Volumes/KOBOeReader" if mac?
    kobo_db_path = "#{watch_path}/.kobo/KoboReader.sqlite"

    FileUtils.mkdir_p(STATE_DIR)

    # Install the sync script (shared between macOS and Linux)
    script_source = File.join(SUPPORT_DIR, "kobo-sync-on-mount.sh")
    script_dest = File.join(STATE_DIR, "kobo-sync-on-mount.sh")
    script_content = File.read(script_source)
    script_content.gsub!("{{KOBO_SYNC_DIR}}", __dir__)
    script_content.gsub!("{{KOBO_DB}}", kobo_db_path)
    script_content.gsub!("{{LOG_FILE_PATH}}", "#{STATE_DIR}/sync.log")
    File.write(script_dest, script_content)
    File.chmod(0755, script_dest)

    if mac?
      FileUtils.mkdir_p(File.dirname(LAUNCHD_PLIST))

      plist_source = File.join(SUPPORT_DIR, "com.kobo-sync.plist")
      plist_content = File.read(plist_source)
      plist_content.gsub!("{{SCRIPT_PATH}}", script_dest)
      plist_content.gsub!("{{HOME}}", ENV["HOME"])
      File.write(LAUNCHD_PLIST, plist_content)

      system("launchctl unload #{LAUNCHD_PLIST} 2>/dev/null")
      if system("launchctl load #{LAUNCHD_PLIST}")
        puts "✓ Automation installed (launchd)"
        puts "  Plist: #{LAUNCHD_PLIST}"
      else
        abort "Error: Failed to load launchd agent"
      end
    elsif linux?
      FileUtils.mkdir_p(SYSTEMD_USER_DIR)

      # Derive systemd mount unit name from path
      mount_unit = watch_path.chomp("/").gsub("/", "-").sub(/\A-/, "") + ".mount"

      service_dest = File.join(SYSTEMD_USER_DIR, "kobo-sync.service")
      service_content = File.read(File.join(SUPPORT_DIR, "kobo-sync.service"))
      service_content.gsub!("{{MOUNT_UNIT}}", mount_unit)
      service_content.gsub!("{{SCRIPT_PATH}}", script_dest)
      service_content.gsub!("{{LOG_PATH}}", "#{STATE_DIR}/systemd.log")
      File.write(service_dest, service_content)

      # Create WantedBy symlink manually — the mount unit only exists when the device
      # is plugged in, so `systemctl enable` would fail with "dependency on non-existent unit"
      wants_dir = File.join(SYSTEMD_USER_DIR, "#{mount_unit}.wants")
      FileUtils.mkdir_p(wants_dir)
      FileUtils.ln_s(File.join("..", "kobo-sync.service"), File.join(wants_dir, "kobo-sync.service"), force: true)

      system("systemctl", "--user", "daemon-reload")
      if $?.success?
        puts "✓ Automation installed (systemd)"
        puts "  Service: #{service_dest}"
        puts "  Bound to: #{mount_unit}"
      else
        abort "Error: Failed to reload systemd. Run: systemctl --user daemon-reload"
      end
    end

    puts "  Script: #{script_dest}"
    puts "  Log: #{STATE_DIR}/sync.log"
    puts ""
    puts "Kobo sync will now run automatically when you mount your Kobo."
  end

  desc "Uninstall automation"
  task :uninstall do
    if mac?
      if File.exist?(LAUNCHD_PLIST)
        system("launchctl unload #{LAUNCHD_PLIST} 2>/dev/null")
        File.delete(LAUNCHD_PLIST)
        puts "✓ Automation uninstalled (launchd)"
      else
        puts "Automation was not installed"
      end
    elsif linux?
      service_path = File.join(SYSTEMD_USER_DIR, "kobo-sync.service")
      removed = false

      if File.exist?(service_path)
        system("systemctl", "--user", "disable", "--now", "kobo-sync.service", out: File::NULL, err: File::NULL)
        File.delete(service_path)
        removed = true
      end

      # Remove WantedBy symlinks created during install
      Dir[File.join(SYSTEMD_USER_DIR, "*.mount.wants")].each do |wants_dir|
        link = File.join(wants_dir, "kobo-sync.service")
        if File.symlink?(link)
          File.delete(link)
          removed = true
        end
        Dir.rmdir(wants_dir) if Dir.exist?(wants_dir) && Dir.empty?(wants_dir)
      end

      if removed
        system("systemctl", "--user", "daemon-reload")
        puts "✓ Automation uninstalled (systemd)"
      else
        puts "Automation was not installed"
      end
    end

    script_path = File.join(STATE_DIR, "kobo-sync-on-mount.sh")
    File.delete(script_path) if File.exist?(script_path)
    old_script = File.join(STATE_DIR, "sync-on-mount.sh")
    File.delete(old_script) if File.exist?(old_script)
  end

  desc "Check automation status"
  task :status do
    if mac?
      if File.exist?(LAUNCHD_PLIST)
        loaded = `launchctl list 2>/dev/null | grep #{LAUNCHD_LABEL}`.strip
        if loaded.empty?
          puts "Automation: installed but not loaded"
          puts "  Run: launchctl load #{LAUNCHD_PLIST}"
        else
          puts "✓ Automation: installed and running (launchd)"
        end
        puts "  Plist: #{LAUNCHD_PLIST}"
      else
        puts "Automation: not installed"
        puts "  Run: rake automation:install"
      end
    elsif linux?
      service_path = File.join(SYSTEMD_USER_DIR, "kobo-sync.service")
      if File.exist?(service_path)
        status = `systemctl --user is-enabled kobo-sync.service 2>/dev/null`.strip
        if status == "enabled"
          puts "✓ Automation: installed and enabled (systemd)"
        else
          puts "Automation: installed but not enabled"
        end
        puts "  Service: #{service_path}"
      else
        puts "Automation: not installed"
        puts "  Run: rake automation:install"
      end
    end
    puts "  Log: #{STATE_DIR}/sync.log"
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

    db = SQLite3::Database.new(kobo_db)

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
    user_db = SQLite3::Database.new(kobo_db)
    privacy = user_db.get_first_value("SELECT PrivacyPermissions FROM user")
    user_db.close

    if privacy && privacy.bytesize > 4
      puts "✓ Analytics enabled (PrivacyPermissions is set)"
    else
      puts "✗ Analytics disabled (PrivacyPermissions is empty)"
      puts "  No reading events will be recorded."
      puts "  Temporarily set api_endpoint to https://storeapi.kobo.com,"
      puts "  sync with Kobo's servers, accept the privacy consent,"
      puts "  then restore the BookLore endpoint."
    end
  end
end

desc "Default: check Kobo status"
task default: "kobo:check"