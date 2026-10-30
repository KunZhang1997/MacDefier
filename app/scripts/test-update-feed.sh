#!/usr/bin/env bash
# Isolated ZIP fixtures + fake signing tools; no Keychain, notary, build or public writes.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bash -n "$script_dir/package-release.sh" "$script_dir/generate-update-feed.sh"
ruby - "$script_dir/generate-update-feed.sh" "$script_dir/package-release.sh" <<'RUBY'
require 'base64'
require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'

generator, packager = ARGV
passed = 0
key = Base64.strict_encode64("\x01" * 32)
Dir.mktmpdir('MacDefier-update-tests.', '/private/tmp') do |scratch|
  bin = File.join(scratch, 'tools')
  FileUtils.mkdir_p(bin)
  File.write(File.join(bin, 'generate_keys'), <<~'SH')
    #!/usr/bin/env bash
    [[ "$*" == '--account com.macdefier.app.sparkle -p' ]] || exit 9
    [[ "${FIXTURE_MISSING_KEY:-0}" != 1 ]] || exit 1
    printf '%s\n' "$FIXTURE_PUBLIC_KEY"
  SH
  File.write(File.join(bin, 'generate_appcast'), <<~'SCRIPT')
    #!/usr/bin/env ruby
    require 'cgi'
    output = ARGV[ARGV.index('-o') + 1]
    prefix = ARGV[ARGV.index('--download-url-prefix') + 1]
    archive = Dir[File.join(ARGV.last, '*.zip')].fetch(0)
    version = ENV.fetch('FIXTURE_FEED_BUILD', '0.16')
    short = ENV.fetch('FIXTURE_FEED_SHORT', '0.16')
    length = File.size(archive) + ENV.fetch('FIXTURE_LENGTH_OFFSET', '0').to_i
    signature = ENV['FIXTURE_UNSIGNED'] == '1' ? '' : 'fixture-archive-signature'
    File.write(output, %(<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>#{version}</sparkle:version><sparkle:shortVersionString>#{short}</sparkle:shortVersionString><enclosure url="#{CGI.escapeHTML(prefix + File.basename(archive))}" length="#{length}" sparkle:edSignature="#{signature}"/></item></channel></rss>))
  SCRIPT
  File.write(File.join(bin, 'sign_update'), <<~'SCRIPT')
    #!/usr/bin/env ruby
    abort 'wrong signing account' unless ARGV.shift(2) == ['--account', 'com.macdefier.app.sparkle']
    if ARGV.first == '--verify'
      ARGV.shift
      path = ARGV.shift
      if File.extname(path) == '.xml'
        abort 'unsigned feed' unless File.read(path).include?('fixture-feed-signed')
      else
        abort 'wrong archive signature' unless ARGV.shift == 'fixture-archive-signature'
      end
    else
      File.open(ARGV.fetch(0), 'a') { |f| f.write("\n<!-- fixture-feed-signed -->\n") }
    end
  SCRIPT
  File.write(File.join(bin, 'codesign'), "#!/usr/bin/env bash\nif [[ -n \"${FIXTURE_SIGN_LOG:-}\" ]]; then printf '%s\\n' \"$*\" >> \"$FIXTURE_SIGN_LOG\"; fi\n")
  File.write(File.join(bin, 'file'), "#!/usr/bin/env bash\nprintf '%s\\n' 'Mach-O 64-bit executable'\n")
  Dir[File.join(bin, '*')].each { |path| File.chmod(0755, path) }

  fixture = lambda do |name, overrides = {}, extra_env = {}, success = false|
    directory = File.join(scratch, name)
    app = File.join(directory, 'MacDefier.app')
    FileUtils.mkdir_p(File.join(app, 'Contents'))
    values = {
      'CFBundleIdentifier' => 'com.macdefier.app', 'CFBundleVersion' => '0.16',
      'CFBundleShortVersionString' => '0.16', 'SUPublicEDKey' => key,
      'SURequireSignedFeed' => true, 'SUVerifyUpdateBeforeExtraction' => true,
      'SUFeedURL' => 'https://github.com/KunZhang1997/MacDefier/releases/latest/download/appcast.xml'
    }.merge(overrides)
    entries = values.map { |k, v| "<key>#{k}</key>" + (v == true ? '<true/>' : v == false ? '<false/>' : "<string>#{v}</string>") }.join
    File.write(File.join(app, 'Contents', 'Info.plist'), "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>#{entries}</dict></plist>")
    archive = File.join(directory, 'MacDefier-0.16.zip')
    raise 'fixture zip failed' unless system('/usr/bin/ditto', '-c', '-k', '--keepParent', app, archive)
    output = File.join(directory, 'appcast.xml')
    File.write(output, 'previous-feed')
    digest = Digest::SHA256.file(archive).hexdigest
    env = {
      'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'MACDEFIER_SPARKLE_TOOLS_DIR' => bin,
      'FIXTURE_PUBLIC_KEY' => key, 'MACDEFIER_RELEASE_TAG' => 'v0.16',
      'MACDEFIER_UPDATE_REPOSITORY' => 'KunZhang1997/MacDefier'
    }.merge(extra_env)
    stdout, stderr, status = Open3.capture3(env, '/bin/bash', generator, archive, '0.16')
    raise "#{name}: unexpected result\n#{stdout}\n#{stderr}" unless status.success? == success
    raise "#{name}: archive was modified" unless Digest::SHA256.file(archive).hexdigest == digest
    if success
      raise "#{name}: feed was not signed" unless File.read(output).include?('fixture-feed-signed')
    else
      raise "#{name}: previous feed changed on failure" unless File.read(output) == 'previous-feed'
    end
    passed += 1
  end
  fixture.call('signed-success', {}, {}, true)
  fixture.call('actual-build-not-tag', { 'CFBundleVersion' => '22' }, { 'FIXTURE_FEED_BUILD' => '22' }, true)
  fixture.call('missing-key', {}, { 'FIXTURE_MISSING_KEY' => '1' })
  fixture.call('public-key-mismatch', { 'SUPublicEDKey' => Base64.strict_encode64("\x02" * 32) })
  fixture.call('renamed-old-archive', { 'CFBundleShortVersionString' => '0.14' })
  fixture.call('debug-bundle', { 'CFBundleIdentifier' => 'com.macdefier.app.dev' })
  fixture.call('unsigned-feed-flag', { 'SURequireSignedFeed' => false })
  fixture.call('unverified-extraction', { 'SUVerifyUpdateBeforeExtraction' => false })
  fixture.call('wrong-feed-url', { 'SUFeedURL' => 'https://example.invalid/appcast.xml' })
  fixture.call('non-github-repository', {}, { 'MACDEFIER_UPDATE_REPOSITORY' => 'https://example.invalid/repo' })
  fixture.call('wrong-feed-build', {}, { 'FIXTURE_FEED_BUILD' => '0.15' })
  fixture.call('wrong-length', {}, { 'FIXTURE_LENGTH_OFFSET' => '1' })
  fixture.call('missing-archive-signature', {}, { 'FIXTURE_UNSIGNED' => '1' })

  # Check the configured public key before an expensive release build; no key generation.
  preflight_app = File.join(scratch, 'preflight-app')
  FileUtils.mkdir_p(File.join(preflight_app, 'scripts'))
  preflight_script = File.join(preflight_app, 'scripts', 'generate-update-feed.sh')
  FileUtils.cp(generator, preflight_script)
  preflight_project = File.join(preflight_app, 'project.yml')
  File.write(preflight_project, "targets:\n  MacDefier:\n    info:\n      properties:\n        SUPublicEDKey: #{key}\n")
  env = { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'MACDEFIER_SPARKLE_TOOLS_DIR' => bin, 'FIXTURE_PUBLIC_KEY' => key }
  _, stderr, status = Open3.capture3(env, '/bin/bash', preflight_script, '--check-signing')
  raise "matching preflight key failed: #{stderr}" unless status.success?
  passed += 1
  File.write(preflight_project, "targets:\n  MacDefier:\n    info:\n      properties:\n        SUPublicEDKey: mismatch\n")
  _, stderr, status = Open3.capture3(env, '/bin/bash', preflight_script, '--check-signing')
  raise 'mismatched configured key passed preflight' if status.success? || !stderr.include?('does not match Keychain')
  passed += 1
  _, stderr, status = Open3.capture3(env.merge('FIXTURE_MISSING_KEY' => '1'), '/bin/bash', preflight_script, '--check-signing')
  raise 'missing key passed preflight' if status.success? || !stderr.include?('signing key unavailable')
  passed += 1

  # Exercise only the extracted signing helper, never package-release's build/notary flow.
  helper = File.read(packager)[/^sign_nested_code\(\) \{\n.*?^\}/m] or raise 'missing signing helper'
  app = File.join(scratch, 'signing', 'MacDefier.app')
  framework = File.join(app, 'Contents', 'Frameworks', 'Sparkle.framework')
  xpc = File.join(framework, 'Versions', 'B', 'XPCServices', 'Installer.xpc')
  updater = File.join(framework, 'Versions', 'B', 'Updater.app')
  binaries = [File.join(app, 'Contents', 'MacOS', 'MacDefier'), File.join(xpc, 'Contents', 'MacOS', 'Installer'), File.join(updater, 'Contents', 'MacOS', 'Updater')]
  binaries.each { |path| FileUtils.mkdir_p(File.dirname(path)); File.write(path, 'fixture'); File.chmod(0755, path) }
  log = File.join(scratch, 'signing.log')
  env = { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'FIXTURE_SIGN_LOG' => log, 'FIXTURE_APP' => app }
  stdout, stderr, status = Open3.capture3(env, '/bin/bash', '-c', helper + "\nsign_nested_code \"$FIXTURE_APP\" fixture-identity\n")
  raise "signing helper failed: #{stdout} #{stderr}" unless status.success?
  calls = File.readlines(log).map(&:strip)
  locate = lambda { |path| calls.index { |line| line.end_with?(" #{path}") } || raise("not signed: #{path}") }
  raise 'main app binary signed before entitlements' if calls.any? { |line| line.end_with?(" #{binaries.first}") }
  raise 'XPC signing order' unless locate.call(binaries[1]) < locate.call(xpc) && locate.call(xpc) < locate.call(framework)
  raise 'Updater signing order' unless locate.call(binaries[2]) < locate.call(updater) && locate.call(updater) < locate.call(framework)
  raise 'helper entitlements not preserved' unless calls.all? { |line| line.include?('--preserve-metadata=entitlements') }
  passed += 1
end
puts "UpdateFeedSmoke: PASS (#{passed} cases; fake signing tools; real isolated ZIP metadata; no Keychain/build/notary/upload)"
RUBY
