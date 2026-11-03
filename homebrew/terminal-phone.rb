# Copy into your tap repository (govijr/homebrew-tap) as Formula/terminal-phone.rb.
# After each release, update url and sha256 (the release workflow prints the sha256 in its summary).
class TerminalPhone < Formula
  desc "Interactive iPhone simulator and real-iPhone control in your terminal, for you and your AI agents"
  homepage "https://github.com/govijr/terminal-phone"
  url "https://github.com/govijr/terminal-phone/archive/refs/tags/v0.3.0.tar.gz"
  sha256 "REPLACE_WITH_SOURCE_TARBALL_SHA256"
  license "MIT"
  head "https://github.com/govijr/terminal-phone.git", branch: "main"

  depends_on xcode: "26.0"
  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "terminal-phone"
    libexec.install ".build/release/terminal-phone"
    (libexec/"resources").install Dir["resources/phone-*"]
    (libexec/"agent").install "docs/TERMINAL-PHONE-AGENT.md" => "AGENT.md"
    # The CLI finds resources next to its resolved executable, so a symlink is enough.
    bin.install_symlink libexec/"terminal-phone"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/terminal-phone version")
  end
end
