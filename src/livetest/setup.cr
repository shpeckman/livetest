# :nodoc:
# Registers the running executable with KWin so `org.kde.KWin.ScreenShot2`
# answers it: a desktop file naming the executable and the restricted
# interface, then a rebuilt KService cache.
module Livetest::Setup
  # Returns the path of the desktop file for *executable*, named after it.
  def self.path(executable : String) : String
    data = ENV["XDG_DATA_HOME"]? || File.join(Path.home.to_s, ".local", "share")
    File.join(data, "applications", "#{File.basename(executable)}.desktop")
  end

  # Writes the desktop file for *executable* and refreshes the cache;
  # returns the desktop file's path.
  def self.install(executable : String) : String
    file = path(executable)
    Dir.mkdir_p(File.dirname(file))
    File.write(file, <<-DESKTOP)
      [Desktop Entry]
      Type=Application
      Name=#{File.basename(executable)}
      Comment=Live test harness
      Exec=#{executable}
      NoDisplay=true
      X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2

      DESKTOP
    Process.run("kbuildsycoca6", output: Process::Redirect::Close, error: Process::Redirect::Close) rescue nil
    file
  end
end
