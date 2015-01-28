require 'shellwords'
require 'yaml'
require 'fileutils'

module IOSRakeFileTools
	def self.output_log (log_str)
		puts "[RAKEFILE LOG] #{log_str}"
	end

	def self.output_shell_command (command_str)
		puts "[RAKEFILE SHELL COMMAND] #{command_str}"
	end

	def self.execute_shell_command (command_str)
		puts output_shell_command(command_str)

		process = IO.popen(command_str) do |io|
			while line = io.gets
				line.chomp!
				puts line
			end
			io.close
		end

		status_code = $?    
		if status_code.to_i != 0
			output_log("Command did fail with exit status (#{status_code})")
			fail # GO isn't picking up the failed xcodebuild command return status, therefore we explicitly fail the rake task
		end
	end

	def self.close_simulator
		`osascript -e 'tell app "iOS Simulator" to quit'`
	end

	def self.open_simulator
		`osascript -e 'tell app "iOS Simulator" to activate'`
	end

	def self.clean_build(project_dir = '.')
		FileUtils.cd(project_dir) do
			execute_shell_command("xcodebuild -alltargets clean")
		end

		derived_data_dir=File.expand_path "~/Library/Developer/Xcode/DerivedData"
		if File.exists?(derived_data_dir)
			output_shell_command("rm -rf #{derived_data_dir}")
			FileUtils.rm_r(derived_data_dir)
		end    	   	
	end

	class Builder
		def initialize(configuration)
			@configuration = configuration
			if configuration.key? :build_dir_unescaped
				@configuration[:build_dir_escaped] = "#{Shellwords.escape("#{BUILD_DIR_UNESCAPED}")}" # Need to escape the space between "Go" and "Agent" in "Go Agent.app" 
			end
		end

		def update_version
			if !([:marketing_version, :full_version].all? {|s| @configuration.key? s})
				return
			end

			project_dir = (@configuration.key? :project_dir_unescaped) ? @configuration[:project_dir_unescaped] : '.'			

			FileUtils.cd(project_dir) do
				IOSRakeFileTools.output_log("Updating major version")
				IOSRakeFileTools.execute_shell_command("agvtool new-marketing-version #{@configuration[:marketing_version]}")
				IOSRakeFileTools.output_log("Updating minor version")
				IOSRakeFileTools.execute_shell_command("agvtool new-version -all #{@configuration[:full_version]}")
				IOSRakeFileTools.output_log("Version updating complete")
			end
		end

		def archive(build_type = "Release")
			if !([:build_dir_unescaped, :workspace, :scheme, :xcconfig, :build_dir_escaped, :file_name].all? {|s| @configuration.key? s})
				return
			end

			FileUtils.rm_r(@configuration[:build_dir_unescaped]) if File.exists?(@configuration[:build_dir_unescaped])
			FileUtils.mkdir(@configuration[:build_dir_unescaped])

			IOSRakeFileTools.execute_shell_command("xcodebuild archive -sdk iphoneos -workspace #{@configuration[:workspace]} -configuration #{build_type} -scheme #{@configuration[:scheme]} -xcconfig #{@configuration[:xcconfig]} -archivePath #{@configuration[:build_dir_escaped]}/#{@configuration[:file_name]}")

			zip_archive
		end

		def zip_archive
			IOSRakeFileTools.output_log("Zipping archive to upload to GO server")
			FileUtils.cd(@configuration[:build_dir_unescaped]) do 
				IOSRakeFileTools.execute_shell_command("zip -r #{@configuration[:file_name]}.xcarchive.zip #{@configuration[:file_name]}.xcarchive")
			end
		end

		def build(build_type = "Release")
			if !([:workspace, :scheme, :xcconfig, :build_dir_escaped, :file_name].all? {|s| @configuration.key? s})
				return
			end

			IOSRakeFileTools.execute_shell_command("xcodebuild build -sdk iphoneos -workspace #{@configuration[:workspace]} -configuration #{build_type} -scheme #{@configuration[:scheme]} -xcconfig #{@configuration[:xcconfig]}")
		end

		def test(destination)
			if !([:workspace, :scheme].all? {|s| @configuration.key? s})
				return
			end

			IOSRakeFileTools.execute_shell_command("xcodebuild test -sdk iphonesimulator -destination '#{destination}' -workspace #{@configuration[:workspace]} -configuration Debug -scheme #{@configuration[:scheme]}")
		end

		def export_archive_and_upload_to_test_flight(provisioningProfileName)
			zip_dsym

			ipa_file_name = "#{@configuration[:file_name]}_test_flight"
			IOSRakeFileTools.execute_shell_command("xcodebuild -exportArchive -exportFormat IPA -archivePath #{@configuration[:build_dir_escaped]}/#{@configuration[:file_name]}.xcarchive -exportPath #{@configuration[:build_dir_escaped]}/#{ipa_file_name} -exportProvisioningProfile '#{provisioningProfileName}'")

			upload_to_test_flight(ipa_file_name)
		end

		def zip_dsym
			IOSRakeFileTools.output_log("Zipping dSYM")
			FileUtils.cd("#{@configuration[:build_dir_unescaped]}/#{@configuration[:file_name]}.xcarchive/dSYMs") do 
				IOSRakeFileTools.execute_shell_command("zip -r #{@configuration[:build_dir_escaped]}/#{@configuration[:file_name]}.app.dSYM.zip \"#{@configuration[:app_name]}.app.dSYM\"")
			end
		end

		def upload_to_test_flight(ipa_file_name)
			File.open("#{@configuration[:build_dir_unescaped]}/notes.txt", 'w') do |f|
				f.puts(notes)
			end

			api_token = commit_author_test_flight_api_token

			IOSRakeFileTools.output_log("Uploading to Testflight")
			upload_cmd = <<-CMD
			curl http://testflightapp.com/api/builds.json \
			-F file=@build/#{ipa_file_name}.ipa \
			-F api_token='#{api_token}' \
			-F team_token='#{ENV["TESTFLIGHT_TEAM_TOKEN"]}' \
			-F dsym=@build/#{@configuration[:file_name]}.app.dSYM.zip \
			-F notes=@build/notes.txt \
			-F notify=True \
			-F distribution_lists='ios-internal'
			CMD
			IOSRakeFileTools.execute_shell_command("#{upload_cmd}")
		end

		def notes
			revision = %x[git log --oneline --format='%h' -1].chomp
			logs = `git log -10 --pretty=oneline --abbrev-commit | grep -v 'Merge branch'`
			"Version:#{@configuration[:marketing_version]} / #{@configuration[:full_version]} - #{revision}\nLast 10 changes:\n\n#{logs}"
		end 

		def commit_author_test_flight_api_token
			commit_author_email = `git log -1 --format='%ae'`.chomp.downcase

			raw_token_by_author = YAML.load_file('test_flight_api_token_by_author.yaml')
			token_by_lower_case_author = {}
			raw_token_by_author.each do |author, api_token|
				token_by_lower_case_author.merge!({author.downcase => api_token})
			end

			if token_by_lower_case_author.has_key?(commit_author_email)
				api_token = token_by_lower_case_author[commit_author_email].chomp
			else
				api_token = token_by_lower_case_author["default"].chomp
			end

			api_token
		end

		def export_for_app_store(provisioningProfileName)
			ipa_file_name = "#{@configuration[:file_name]}_app_store"
			IOSRakeFileTools.execute_shell_command("xcodebuild -exportArchive -exportFormat IPA -archivePath #{@configuration[:build_dir_escaped]}/#{@configuration[:file_name]}.xcarchive -exportPath #{@configuration[:build_dir_escaped]}/#{ipa_file_name} -exportProvisioningProfile '#{provisioningProfileName}'")

			IOSRakeFileTools.output_log("Checking for Swift support")
			unzipped_ipa_directory_name = "#{ipa_file_name}_unzipped_ipa"
			path_to_unzipped_ipa_directory_unescaped = "#{@configuration[:build_dir_unescaped]}/#{unzipped_ipa_directory_name}"
			path_to_payload_directory_unescaped = "#{path_to_unzipped_ipa_directory_unescaped}/Payload"
			path_to_app_unescaped = "#{path_to_payload_directory_unescaped}/#{@configuration[:app_name]}.app"
			IOSRakeFileTools.execute_shell_command("unzip #{@configuration[:build_dir_escaped]}/#{ipa_file_name}.ipa -d #{@configuration[:build_dir_escaped]}/#{unzipped_ipa_directory_name}")
			project_has_swift_support_directory = File.exists?("#{path_to_unzipped_ipa_directory_unescaped}/SwiftSupport")
			project_has_swift_code = File.exists?("#{path_to_app_unescaped}/Frameworks")
			if !project_has_swift_support_directory && project_has_swift_code
				IOSRakeFileTools.output_log("IPA has NO swift support!")

				IOSRakeFileTools.output_log("Removing old IPA")
				FileUtils.rm_r("#{@configuration[:build_dir_unescaped]}/#{ipa_file_name}.ipa")

				IOSRakeFileTools.output_log("Creating SwiftSupport directory")
				path_to_swift_support_directory_unescaped = "#{path_to_unzipped_ipa_directory_unescaped}/SwiftSupport"
				FileUtils.mkdir_p(path_to_swift_support_directory_unescaped)

				IOSRakeFileTools.output_log("Adding SwiftSupport files")
				Dir.foreach("#{path_to_app_unescaped}/Frameworks") do |swift_lib|
					next if swift_lib == '.' or swift_lib == '..'
					FileUtils.cp_r("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos/#{swift_lib}", path_to_swift_support_directory_unescaped)
				end

				IOSRakeFileTools.output_log("Recreating IPA")
				FileUtils.cd(path_to_unzipped_ipa_directory_unescaped) do
					IOSRakeFileTools.execute_shell_command("zip --symlinks --verbose --recurse-paths #{@configuration[:build_dir_escaped]}/#{ipa_file_name}.ipa .")
				end

				# Not needed for some odd reason. The .ipa just moves by itself into the build directory.
				# IOSRakeFileTools.output_log("Moving IPA back to build directory")
				# FileUtils.mv("#{path_to_unzipped_ipa_directory_unescaped}/#{ipa_file_name}.ipa.zip", "#{@configuration[:build_dir_unescaped]}/#{ipa_file_name}.ipa")
			else
				IOSRakeFileTools.output_log("IPA has swift support!")
			end
		end
	end
end

if __FILE__ == $0
	# IOSRakeFileTools.clean_build(".")
	
	# MARKETING_VERSION="2.6" # e.g. 2.0, 2.1, 2.1.1 (but not 2.0.0 or 2.1.0) not checked during submission; this version should be entered in iTunesConnect before upload; (Apple checks that that version matches either the marketing or bundle version)
	# MAJOR_VERSION="2.6.0" # e.g. 2.0.0, 2.1.0, 2.1.1 (but not 2.0, 2.1) is checked during submission
	# FULL_VERSION="#{MAJOR_VERSION}.4046"
	# BUILD_DIR_UNESCAPED=File.dirname(__FILE__)

	# app_name = "ApplauzeProduction" 
	# build_configuration = {
 #      :app_name => app_name,
 #      :file_name => "#{app_name}_#{FULL_VERSION}",
 #      :marketing_version => MARKETING_VERSION,
 #      :full_version => FULL_VERSION,
 #      :scheme => app_name,
 #      :workspace => "Applauze.xcworkspace",
 #      :build_dir_unescaped => BUILD_DIR_UNESCAPED,
 #      :xcconfig => "ApplauzeDev/Configuration/Production/#{app_name}.xcconfig"
 #    }
    
 #    builder = IOSRakeFileTools::Builder.new(build_configuration)
 #    builder.export_for_app_store("")
end