#!/usr/bin/env ruby

require 'optparse'
require 'fileutils'
require 'pp'
require 'find'
require 'wpcli'
require 'csv'
require 'mail'
require 'uri'
require 'highline/import'

class WPParser

	Version = 0.1

  CODES = %w[gz bz2 xz lzma]
  CODE_ALIASES = { "gzip" => "gz", "bzip2" => "bz2", "lzma" => "xz" }

	def self.parse(args)
		# The options specified on the command line will be collected in *options*.
		# We set default values here.
		options = {
			name: 'wp_updates',
			dest: '/tmp/',
			target: './',
			to: 'root',
			update: 'false',
		    compression: "gz", 
		    switch: "z"
		}

		opts = OptionParser.new do |opts|
			opts.banner = "Usage: #$0 [options]"
			opts.separator ""
			opts.separator "Specific options:"

			# Cast 'target dir' argument to a  object.
			opts.on("-t", "--target TARGET", "Path to begin searching from") do |target| 
				options[:target] = target
			end

			# Cast 'dest' argument to a  object.
			opts.on("-d", "--dest [DESTINATION]", "CSV Destination") do |dest|
				options[:dest] = dest
			end

			# Cast 'name' argument to a  object.
			opts.on("-n", "--name [NAME]", "CSV name") do |name|
				options[:name] = name
			end

			# Cast 'To Address' argument to a  object.
			opts.on("-m", "--mailto [MAILTO]", "Email Recipient") do |to|
				options[:to] = to
			end

			# Boolean Switch for the "Update" variable
			opts.on("-u", "--update-all", "Update Core and Plugins") do |u|
				options[:update] = u
			end

	        code_list = (CODE_ALIASES.keys + CODES).join(',')
   	        opts.on("-c", "--code [CODE]", CODES, CODE_ALIASES, "Select Compression", "  (#{code_list})") do |compression|
       		    options[:compression] = compression
				if compression == "gzip"
					switch = "z"
				elsif compression == "bzip2"
					switch = "j"
				elsif compression == "lzma"
					switch = "J"
           		end
            	options[:switch] = switch
        	end

			# Boolean switch.
			opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
				options[:verbose] = v
			end

			opts.separator ""
			opts.separator "Common options:"

			# No argument, shows at tail.  This will print an options summary.
			opts.on_tail("-h", "--help", "Show this message") do
				puts opts
				exit
			end

			opts.on_tail("-V", "--version", "Show version") do
				puts Version
				exit
			end
		end

		opts.parse!
		options

	end  # parse
end  # class OptionParser

class Iterator

	def initialize(options)
		@options = options 
		@target = @options[:target]
		generate_csv(options)
		@to = @options[:to]
		@@target_csv = Dir.glob("#{@options[:dest]}#{@options[:name]}*\.csv").max_by {|f| File.mtime(f)}
	end


	def wp_found(options)
		begin
			puts "Hello, #{@options[:target]} shall be searched to find WP installations..."
			puts @@target_csv if @options[:verbose]
			Dir.chdir(@target)
			wpconfigs = Array.new()
			Find.find(@options[:target]) do |path|
				wpconfigs << path if path =~ /\/(wp|local)\-config\.php$/
			end

			wpconfigs.each do |file|
				if file =~ /(bak|repo|archive|backup|safe|db|html\w|html\.)/
					next	
				end
				@wpcli = Wpcli::Client.new File.dirname(file)
				puts "Getting plugins for..." 

				ugly_site_name = @wpcli.run "option get siteurl --allow-root"
				site_name = ugly_site_name.to_s.match(URI.regexp).to_s.sub(/^https?\:\/\//, '').sub(/^www./,'')
				CSV.open(@@target_csv, "a") do |csv|
					csv << ["#{site_name}",] 
				end

				puts @options[:update]

				core_update = @wpcli.run "core check-update --allow-root" 
				if core_update.is_a? String
					puts core_update
				elsif core_update.is_a? Array
					core_update.each do |check|			
						puts "#{check[:version]} is a #{check[:update_type]} upgrade" 
						CSV.open(@@target_csv, "a") do |csv|
							csv << ['', 'WordPress Core', check[:version], check[:update_type]]   
						end 
					end 
				end
				plugins = @wpcli.run "plugin list --allow-root"
				plugins.each do |plugin|
					puts "#{plugin[:name]} is version #{plugin[:version]} and an update is #{plugin[:update]}" 
					CSV.open(@@target_csv, "a") do |csv|
						csv << ['', plugin[:name], plugin[:version], plugin[:update]]
					end
				end
				if @options[:update] == true
					exit unless HighLine.agree('This will attempt to backup the wordpress database and all content. Do you want to proceed?')
					archiver(site_name,file,options)
					exit unless HighLine.agree('This will attempt to upgrade WordPress core and all plugins. Do you want to proceed?')
					updatewp()
				end
			end
		rescue => e
			puts e
		end
	end

	def archiver(site_name,file,options)
		export_sql = @wpcli.run "db export #{site_name}.sql --allow-root"
		export_sql
	    @backup_sql = "#{site_name}.sql"
		FileUtils.mv(File.basename(@backup_sql), @options[:dest])
		@backup_target = File.basename(File.dirname(file))
		@backup_parent = File.dirname(File.dirname(file))
		compressor(site_name,options)
	end
	def compressor(site_name,options)
		begin
			tarballed_name = "#{site_name}.tar.#{@options[:compression]}"

			puts "Compressing! with the following algorithm: #{@options[:compression]}"
			Dir.chdir(@options[:dest])
			`tar c#{@options[:switch]}vf #{tarballed_name} #{@backup_sql} -C #{@backup_parent} #{@backup_target}`

			puts "Finished! Checking if #{@options[:dest]}#{@backup_sql} exists..."
			thetruth_sql = File.exist?(File.expand_path("#{@options[:dest]}#{@backup_sql}"))
			
			puts "The existence of #{@backup_sql} is #{thetruth_sql}"
			puts "Deleting #{@options[:dest]}#{@backup_sql}..."
			File.delete(@backup_sql)
			
			thenewtruth = File.exist?(File.expand_path("#{@options[:dest]}#{@backup_sql}"))
			puts "The existence of #{@backup_sql} is #{thenewtruth}"

			deflated = "#{@options[:dest]}#{tarballed_name}"
			puts "Finished! Checking if #{deflated} exists..."
			thetruth_tar = File.exist?(File.expand_path(deflated))
			puts "The existence of #{deflated} is #{thetruth_tar}"
			
			puts `file #{deflated}`
		rescue => e
			puts e
		end
	end # def

		

	def updatewp()
		begin
			@wpcli.run "plugin update --all --allow-root"
			@wpcli.run "core update --allow-root"
			@wpcli.run "core update-db --allow-root"
			@wpcli.run "core verify-checksums --allow-root"
		rescue => e
			puts e
		end
	end

	def generate_csv(options)
		begin
			CSV.open("#{@options[:dest]}/#{@options[:name]}-#{Time.now}.csv", "a+") do |csv|
				csv << ["Site name", "Plugin", "Version", "Upgradeable"]
			end
		rescue => e
			puts e
		end
	end
	def send_mail(options)
		begin
			Mail.deliver do
				from      "ruby_slave@localhost"
				to        @to 
				subject   "Plugin Update Status"
				body      "See attachment for details"
				add_file  Dir.glob(@target_csv)
			end
		rescue => e
			puts e
		end
	end

end # class Iterator


### EXECUTE ###
begin
	options = WPParser.parse(ARGV)

	if options[:verbose]
		pp options 
	else	
		options
	end

	Iterator.new(options).wp_found(options)

rescue => e
	puts e
end


