#!/usr/bin/ruby -W0

require 'digest/md5'
require 'uri'
require 'optparse'
require 'singleton'
require 'net/http'
require 'net/smtp'
require 'pathname'
require 'logger'

class Conf
	include Singleton
	
	def initialize 
		@options = {
			:verbose => false, 
			:debug => false, 
			:quiet => false, 
			:dir => '/var/tmp/wcc',
			:simulate => false,
			:clean => false,
			:tag => 'web change checker2'
		}
	
		optparse = OptionParser.new do|opts|
			opts.banner = "Usage: ruby wcc.rb [options] [config-file]"
			opts.on('-q', '--quiet', 'Show only errors') do @options[:quiet] = true end
			opts.on('-v', '--verbose', 'Output more information') do @options[:verbose] = true end
			opts.on('-d', '--debug', 'Enable debug mode') do @options[:debug] = true end
			opts.on('-o', '--dir DIR', 'Save required files to DIR') do |dir| @options[:dir] = dir end
			opts.on('-s', '--simulate', 'Check for update but does not save any data') do @options[:simulate] = true end
			opts.on('-c', '--clean', 'Removes all hash and diff files') do @options[:clean] = true end
			opts.on('-t', '--tag TAG', 'Sets a tag used in output') do |t| @options[:tag] = t end
			opts.on('-n', '--no-mails', 'Does not send any emails') do @options[:nomails] = true end
			opts.on('-f', '--from MAIL', 'Set sender mail address') do |m| @options[:from] = m end
			opts.on('-h', '--help', 'Display this screen') do
				puts opts
				exit
			end
		end
		optparse.parse!
		
		if @options[:from].to_s.empty?
			$stderr.puts "FATAL: No sender mail address given. See help."
			exit 1
		end
		
		$stderr.puts "WARN: No config file given using default conf file" if ARGV.length == 0 and (!@options[:quiet] or @options[:debug])

		@options[:conf_file] = ARGV[0] || 'conf'
		
		if !File.exists?(@options[:conf_file])
			$stderr.puts "FATAL: Config file '%s' does not exists." % @options[:conf_file]
			exit 1
		end
		
		# create dir for hash files
		Dir.mkdir(@options[:dir]) unless File.directory?(@options[:dir])
		
		if(@options[:clean])
			$stdout.puts "WARN: Clean up hash and diff files" unless @options[:quiet] and !@options[:debug]
			Dir.foreach(@options[:dir]) do |f|
				File.delete(@options[:dir] + "/" + f) if f =~ /^.*\.(md5|site)$/
			end
		end
	end
	
	def options; @options end
	
	def self.sites
		return @sites unless @sites.nil?
		
		conf_file = Conf.instance.options[:conf_file] if conf_file.nil?
		@sites = []
		
		$stdout.puts "DEBUG: Load sites from '%s'" % conf_file if Conf.debug?
		
		File.open(conf_file).each do |line|
			# regex to match required config lines; all other lines are ignored
			if line =~ /^[^#]*?;.*?[;.*?]+;?/
				conf_line = line.strip.split(';')
				@sites << Site.new(conf_line[0], conf_line[1], conf_line[2, conf_line.length])
			end
		end
		
		$stdout.puts "DEBUG: " + @sites.length.to_s + (@sites.length == 1 ? ' site' : ' sites') + " loaded\n" +
			@sites.map { |s| "  " + s.uri.host.to_s + "\n    url: " +
			s.uri.to_s + "\n    id: " + s.id }.join("\n") if Conf.debug?
		@sites
	end
	
	def self.file(path = nil) File.join(self.dir, path) end
	
	# aliases for Conf.instance.options[:option]
	def self.dir; Conf.instance.options[:dir] end
	def self.debug?; Conf.instance.options[:debug] end
	def self.verbose?; (Conf.instance.options[:verbose] and !self.quiet?) or self.debug? end
	def self.quiet?; Conf.instance.options[:quiet] and !self.debug? end
	def self.simulate?; Conf.instance.options[:simulate] end
	def self.tag; Conf.instance.options[:tag] end
	def self.send_mails?; !Conf.instance.options[:nomails] end
	def self.from_mail; Conf.instance.options[:from] end
end

class Site
	attr_accessor :hash, :content
	
	def initialize(url, striphtml, emails)
		@uri = URI.parse(url)
		@id = Digest::MD5.hexdigest(url.to_s)[0...8]
		@striphtml = !!striphtml
		@emails = emails.is_a?(Array) ? emails : [emails]
		load_hash
	end
	
	def uri; @uri end
	def striphtml?; @striphtml end
	def emails; @emails end
	def to_s; @uri.to_s + ';' + (@striphtml ? 'yes' : 'no') + ';' + @emails.join(';') end
	def id; @id end
	def new?; hash.to_s.empty? end
	def hash; @hash.to_s end
	def content; load_content if @content.nil?; @content end
	
	def load_hash
		file = Conf.file(self.id + ".md5")
		if File.exists?(file)
			$stdout.puts "DEBUG: Load hash from file '#{file}'" if Conf.debug?
			File.open(file, "r") { |f| @hash = f.gets; break }
		else
			$stdout.puts "INFO: Site #{uri.host} was never checked before." unless Conf.quiet?
		end
	end
	
	def load_content
		file = Conf.file(self.id + ".site")
		if File.exists?(file)
			$stdout.puts "DEBUG: Read site content from file '#{file}'" if Conf.debug?
			File.open(file, "r") { |f| @content = f.read }
		end
	end
	
	def hash=(hash)
		@hash = hash
		file = Conf.file(self.id + ".md5")
		$stdout.puts "DEBUG: Save new site hash to file '#{file}'" if Conf.debug?
		File.open(file, "w") { |f| f.write(@hash) }
	end
	
	def content=(content)
		@content = content
		file = Conf.file(self.id + ".site")
		$stdout.puts "DEBUG: Save new site content to file '#{file}'" if Conf.debug?
		File.open(file, "w") { |f| f.write(@content) }
	end
end

def checkForUpdate(site)
	$logger.info "Requesting '%s'" % site.uri.to_s
	$stdout.puts "\nINFO: Requesting '%s'" % site.uri.to_s if Conf.verbose?
	begin
		r = Net::HTTP.get_response(site.uri)
	rescue
		$logger.error " Cannot connect to '%s': %s" % [site.uri.to_s, $!.to_s]
		$stderr.puts "ERROR: Cannot connect to '%s': %s" % [site.uri.to_s, $!.to_s]
		return false
	end
	if r.code.to_i != 200
		$logger.warn "Site %s returned %s code. Ignore." % [site.uri.to_s, r.code.to_s]
		$stderr.puts "WARN: Site %s returned %s code. Ignore." % [site.uri.to_s, r.code.to_s] unless Conf.quiet?
		return false
	end
	$logger.info "%s response received" % r.code.to_s
	$stdout.puts "INFO: %s response received" % r.code.to_s if Conf.verbose?
	
	new_hash = Digest::MD5.hexdigest(r.body)
	$logger.debug "Compare hashes...\n  %s\n  %s" % [new_hash.to_s, site.hash.to_s]
	$stdout.puts "DEBUG: Compare hashes...\n  %s\n  %s" % [new_hash.to_s, site.hash.to_s] if Conf.debug?
	return false if new_hash == site.hash
	
	# save old site to tmp file
	File.open("/tmp/wcc-" + site.id + ".site", "w") { |f| f.write(site.content) }
	
	# do update
	site.hash, site.content = new_hash, r.body
	
	# diff between OLD and NEW
	old_label = "OLD (%s)" % File.mtime(Conf.file(site.id + ".md5")).to_s
	new_label = "NEW (%s)" % Time.now.to_s
	diff = %x{diff -U 1 --label "#{old_label}" --label "#{new_label}" /tmp/wcc-#{site.id}.site #{Conf.file(site.id + ".site")}}
	
	Net::SMTP.start('localhost', 25) do |smtp|
		site.emails.each do |mail|
			msg  = "From: #{Conf.from_mail}\n"
			msg += "To: #{mail}\n"
			msg += "Subject: [#{Conf.tag}] #{site.uri.host} changed\n"
			msg += "\n"
			msg += "Change at #{site.uri.to_s} - diff follows:\n\n"
			msg += diff
			
			smtp.send_message msg, Conf.from_mail, mail
		end
	end if Conf.send_mails?
	
	true
end

class MyFormatter
	def call(severity, time, progname, msg)
		#"%s %5s: %s" % [time.strftime('%H:%M:%S'), severity, msg.to_s]
		"%s: %s\n" % [severity, msg.to_s]
	end
end

$logger = Logger.new(STDOUT)
$logger.level = Logger::INFO
$logger.formatter = MyFormatter.new
$logger.progname = Conf.tag

Conf.sites.each do |site|
	updated = checkForUpdate(site)
	$stdout.puts "%s has %s" % [site.uri.host.to_s, (updated ? 'an update' : 'no update')] unless Conf.quiet?
end
