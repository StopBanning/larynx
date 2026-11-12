# Homebrew formula that builds Larynx from source (PLAN-v1 D5, the no-cost path). To publish it, put this file in a
# tap repository named homebrew-larynx; then: brew install stopbanning/larynx/larynx
class Larynx < Formula
  desc "Free, offline dictation for macOS: hold a key, speak, text appears where you type"
  homepage "https://github.com/StopBanning/larynx"
  url "https://github.com/StopBanning/larynx.git", tag: "v0.6.0"
  license "MIT"
  head "https://github.com/StopBanning/larynx.git", branch: "main"

  depends_on arch: :arm64
  depends_on macos: :sequoia
  depends_on xcode: ["16.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/larynx"
    ENV["LARYNX_NO_WARM"] = "1"  # no model download inside the build sandbox; it happens on first launch
    system "./scripts/make-app.sh", prefix
  end

  def caveats
    <<~EOS
      Larynx.app was built into #{opt_prefix}. Copy it to ~/Applications and open it:
        cp -R #{opt_prefix}/Larynx.app ~/Applications/ && open ~/Applications/Larynx.app
      The setup window asks for three permissions (Microphone, Input Monitoring, Accessibility).
      The speech model (about 500 MB) downloads on first launch. Nothing you say leaves your Mac.
    EOS
  end

  test do
    assert_match "Hi there", shell_output("#{bin}/larynx tidy 'um hi there'")
  end
end
