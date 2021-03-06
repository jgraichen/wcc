#!/usr/bin/ruby -KuW0

require 'digest/md5'
require 'uri'
require 'optparse'
require 'singleton'
require 'net/http'
require 'net/https'
require 'net/smtp'
require 'pathname'
require 'logger'
require 'iconv'
require 'base64'
require 'yaml'
require 'tempfile'

# ruby gem dependencies
require 'rubygems'
require 'htmlentities'

DIFF_TIME_FMT = '%Y-%m-%d %H:%M:%S %Z'

class Conf
	include Singleton
	
	# use Conf like a hash containing all options
	def [](key)
		@options[key.to_sym] || Conf.default[key.to_sym]
	end
	def []=(key, val)
		@options[key.to_sym] = val unless val.nil?
	end
	
	def self.default
		@default_conf ||= {
			:verbose => false,
			:debug => false,
			:simulate => false,
			:clean => false,
			:nomails => false,
			:dir => '/var/tmp/wcc',
			:tag => 'wcc',
			:syslog => false,
			:filterd => './filter.d',
			:mailer => 'smtp',
			:smtp_host => 'localhost',
			:smtp_port => 25
		}
	end
	
	def initialize
		@options = {}
		
		OptionParser.new do |opts|
			opts.banner = "Usage: ruby wcc.rb [options] [config-yaml-file]"
			opts.on('-v', '--verbose', 'Output more information') do self[:verbose] = true end
			opts.on('-d', '--debug', 'Enable debug mode') do self[:debug] = true end
			opts.on('-o', '--dir DIR', 'Save required files to DIR') do |dir| self[:dir] = dir end
			opts.on('-s', '--simulate', 'Check for update but does not save any data') do self[:simulate] = true end
			opts.on('-c', '--clean', 'Removes all hash and diff files') do self[:clean] = true end
			opts.on('-t', '--tag TAG', 'Sets TAG used in output') do |t| self[:tag] = t end
			opts.on('-n', '--no-mails', 'Does not send any emails') do self[:nomails] = true end
			opts.on('-f', '--from MAIL', 'Set sender mail address') do |m| self[:from_mail] = m end
			opts.on('--host HOST', 'Sets SMTP host') do |h| self[:host] = h end
			opts.on('--port PORT', 'Sets SMTP port') do |p| self[:port] = p end
			opts.on('--show-config', 'Show config after loading config file.') do self[:show_config] = true end
			opts.on('-h', '-?', '--help', 'Display this screen') do
				puts opts
				exit
			end
		end.parse!
		
		logger.progname = 'wcc'

		# latest flag overrides everything
		logger.level = Logger::ERROR
		logger.level = Logger::INFO if self[:verbose]
		logger.level = Logger::DEBUG if self[:debug]

		logger.info "No config file given, using default 'conf.yml' file" if ARGV.length == 0

		self[:conf] = ARGV[0] || 'conf.yml'
		
		if !File.exists?(self[:conf])
			logger.fatal "Config file '#{self[:conf]}' does not exist!"
			exit 1
		end
		
		logger.debug "Load config from '#{self[:conf]}'"
		
		# may be false if file is empty
		yaml = YAML.load_file(self[:conf])
		if yaml.is_a?(Hash) and (yaml = yaml['conf']).is_a?(Hash)
			@options[:from_mail] ||= yaml['from_addr']
			@options[:dir] ||= yaml['cache_dir']
			@options[:tag] ||= yaml['tag']
			@options[:syslog] ||= yaml['use_syslog']
			@options[:filterd] ||= yaml['filterd']
			
			if yaml['email'].is_a?(Hash)
				if yaml['email']['smtp'].is_a?(Hash)
					@options[:mailer] = 'smtp'
					@options[:smtp_host] ||= yaml['email']['smtp']['host']
					# yaml parser should provide an integer here
					@options[:smtp_port] ||= yaml['email']['smtp']['port']
				end
			end
		end
		
		if self[:from_mail].to_s.empty?
			logger.fatal "No sender mail address given! See help."
			exit 1
		end
		
		if self[:show_config]
			Conf.default.merge(@options).each do |k,v|
				puts "  #{k.to_s} => #{self[k]}"
			end
			exit 0
		end
		
		# create dir for hash files
		Dir.mkdir(self[:dir]) unless File.directory?(self[:dir])
		
		if(self[:clean])
			logger.warn "Cleanup hash and diff files"
			Dir.foreach(self[:dir]) do |f|
				File.delete(self.file(f)) if f =~ /^.*\.(md5|site)$/
			end
		end
		
		# read filter.d
		Dir[File.join(self[:filterd], '*.rb')].each { |file| require file }
	end
	
	def self.sites
		return @sites unless @sites.nil?
		
		@sites = []
		
		logger.debug "Load sites from '#{Conf[:conf]}'"
		
		# may be false if file is empty
		yaml = YAML.load_file(Conf[:conf])
		
		yaml['sites'].to_a.each do |yaml_site|
			filterrefs = []
			(yaml_site['filters'] || []).each do |entry|
				if entry.is_a?(Hash)
					# hash containing only one key (filter id),
					# the value is the argument hash
					id = entry.keys[0]
					filterrefs << FilterRef.new(id, entry[id])
				else entry.is_a?(String)
					filterrefs << FilterRef.new(entry, {})
				end
			end
			
			if not yaml_site['cookie'].nil?
				cookie = File.open(yaml_site['cookie'], 'r') { |f| f.read }
			end
			
			@sites << Site.new(
				yaml_site['url'], 
				yaml_site['strip_html'] || false, 
				yaml_site['emails'].map { |m| MailAddress.new(m) } || [],
				filterrefs,
				yaml_site['auth'] || {},
				cookie)
		end if yaml
		
		logger.debug @sites.length.to_s + (@sites.length == 1 ? ' site' : ' sites') + " loaded\n" +
			@sites.map { |s| "  #{s.uri.host.to_s}\n    url: #{s.uri.to_s}\n    id: #{s.id}" }.join("\n")
		
		@sites
	end
	
	def self.mailer
		if @mailer.nil?
			# smtp mailer
			if Conf[:mailer] == 'smtp'
				@mailer = SmtpMailer.new(Conf[:smtp_host], Conf[:smtp_port])
			end
		end
		@mailer
	end
	
	def self.file(path = nil) File.join(self[:dir], path) end
	def self.simulate?; self[:simulate] end
	def self.send_mails?; !self[:nomails] end
	def self.[](key); Conf.instance[key] end
end

class FilterRef
	def initialize(id, arguments)
		@id = id
		@arguments = arguments
	end
	
	def id; @id end
	def arguments; @arguments end
	
	def to_s; @id end
end

class Site
	def initialize(url, strip_html, emails, filters, auth, cookie)
		@uri = URI.parse(url)
		@striphtml = strip_html
		@emails = emails.is_a?(Array) ? emails : [emails]
		@filters = filters.is_a?(Array) ? filters : [filters]
		@auth = auth
		@cookie = cookie
		@id = Digest::MD5.hexdigest(url.to_s)[0...8]
		load_hash
	end
	
	# TODO: attr_reader
	def uri; @uri end
	def striphtml?; @striphtml end
	def emails; @emails end
	def filters; @filters end
	def auth; @auth end
	def cookie; @cookie end
	def id; @id end
	
	def to_s; "%s;%s;%s" % [@uri.to_s, (@striphtml ? 'yes' : 'no'), @emails.join(';')] end
	
	# invalid hashes are nil and "" - nil.to_s is ""
	def new?; self.hash.to_s.empty? end
	def hash; @hash.to_s end
	def content; load_content if @content.nil?; @content end
	
	def load_hash
		file = Conf.file(self.id + '.md5')
		if File.exists?(file)
			logger.debug "Load hash from file '#{file}'"
			File.open(file, 'r') { |f| @hash = f.gets; break }
		else
			logger.info "Site #{uri.host} was never checked before."
		end
	end
	
	def load_content
		file = Conf.file(self.id + '.site')
		File.open(file, 'r') { |f| @content = f.read } if File.exists?(file)
	end
	
	def hash=(hash)
		@hash = hash
		File.open(Conf.file(self.id + '.md5'), 'w') { |f| f.write(@hash) } unless Conf.simulate?
	end
	
	def content=(content)
		@content = content
		File.open(Conf.file(self.id + '.site'), 'w') { |f| f.write(@content) } unless Conf.simulate?
	end
end

class MailAddress
	def initialize(email)
		email = email.to_s if email.is_a?(MailAddress)
		@email = email.strip
	end
	
	def name
		if @email =~ /^[\w\s]+<.+@[^@]+>$/
			@email.gsub(/<.+?>/, '').strip
		else
			@email.split("@")[0...-1].join("@")
		end
	end

	def address
		if @email =~ /^[\w\s]+<.+@[^@]+>$/
			@email.match(/<([^>]+@[^@>]+)>/)[1]
		else
			@email
		end
	end
	
	def to_s; @email end
end

class Mail
	def initialize(title, message, options = {})
		@title = title
		@message = message
		@options = {:from => MailAddress.new(Conf[:from_mail])}
		@options[:from] = MailAddress.new(options[:from]) unless options[:from].nil?
	end
	def title; @title end
	def text; @message end
	def send(tos = [])
		Conf.mailer.send(self, @options[:from], tos)
	end
end

class SmtpMailer
	def initialize(host, port)
		@host = host
		@port = port
	end
	def send(mail, from, to = [])
		Net::SMTP.start(@host, @port) do |smtp|
			to.each do |toaddr|
				msg  = "From: #{from.name} <#{from.address}>\n"
				msg += "To: #{toaddr}\n"
				msg += "Subject: #{mail.title.gsub(/\s+/, ' ')}\n"
				msg += "Content-Type: text/plain; charset=\"utf-8\"\n"
				msg += "Content-Transfer-Encoding: base64\n"
				msg += "\n"
				msg += Base64.encode64(mail.text)
				
				smtp.send_message(msg, from.address, toaddr.address)
			end
		end
	rescue
		logger.fatal "Cannot send mails at #{@host}:#{@port} : #{$!.to_s}"
	end
end

class Filter
	@@filters = {}
	
	def self.add(id, &block)
		logger.info "Adding filter '#{id}'"
		@@filters[id] = block
	end
	
	def self.accept(data, filters)
		return true if filters.nil?
		
		logger.info "Testing with filters: #{filters.join(', ')}"
		
		filters.each do |filterref|
			block = @@filters[filterref.id]
			
			if block.nil?
				logger.error "Requested filter '#{filterref.id}' not found, skipping it."
				next
			end
			
			if not block.call(data, filterref.arguments)
				logger.info "Filter #{filterref.id} failed!"
				return false
			end
		end
		true
	end
end

class String
	def strip_html
		# remove all HTML <tags> with at least 1 character name
		# and decode all HTML entities into UTF-8 characters
		HTMLEntities.new.decode(self.gsub(/<[^>]+>/, ' '))
	end
end

def fetch(site)
	http = Net::HTTP.new(site.uri.host, site.uri.port)
	if site.uri.is_a?(URI::HTTPS)
		http.use_ssl = true
		http.verify_mode = OpenSSL::SSL::VERIFY_NONE
	end
	http.start do |http|
		req = Net::HTTP::Get.new(site.uri.request_uri)
		if site.auth['type'] == 'basic'
			logger.debug "Doing basic auth"
			req.basic_auth(site.auth['username'], site.auth['password'])
		end
		if not site.cookie.nil?
			req.add_field("Cookie", site.cookie)
		end
		http.request(req)
	end
end

def checkForUpdate(site)
	logger.info "Requesting '#{site.uri.to_s}'"
	begin
		res = fetch(site)
	rescue => ex
		logger.error "Cannot connect to #{site.uri.to_s} : #{ex.to_s}"
		return false
	end
	if not res.kind_of?(Net::HTTPOK)
		logger.error "Site #{site.uri.to_s} returned #{res.code} code, skipping it."
		return false
	end
	
	new_content = res.body
	
	# detect encoding from http header, meta element, default utf-8
	# do not use utf-8 regex because it will fail on non utf-8 pages
	encoding = (res['content-type'].to_s.match(/;\s*charset=([A-Za-z0-9-]*)/i).to_a[1] || 
				new_content.match(/<meta.*charset=([a-zA-Z0-9-]*).*/i).to_a[1]).to_s.downcase || 'utf-8'
	
	logger.info "Encoding is '#{encoding}'"
	
	# convert to utf-8
	begin
		new_content = Iconv.conv('utf-8', encoding, new_content)
	rescue
		logger.error "Cannot convert site from '#{encoding}': #{$!.to_s}"
		return false
	end
	
	# strip html _before_ diffing
	new_content = new_content.strip_html if site.striphtml?
	new_hash = Digest::MD5.hexdigest(new_content)
	
	logger.debug "Compare hashes\n  old: #{site.hash.to_s}\n  new: #{new_hash.to_s}"
	return false if new_hash == site.hash
	
	# do not try diff or anything if site was never checked before
	if site.new?
		# update content
		site.hash, site.content = new_hash, new_content
		
		# set custom diff message
		diff = "Site was first checked so no diff was possible."
	else
		# save old site to tmp file
		old_site_file = Tempfile.new("wcc-#{site.id}-")
		old_site_file.write(site.content)
		old_site_file.close
		
		# calculate labels before updating
		old_label = "OLD (%s)" % File.mtime(Conf.file(site.id + ".md5")).strftime(DIFF_TIME_FMT)
		new_label = "NEW (%s)" % Time.now.strftime(DIFF_TIME_FMT)
	
		# do update
		site.hash, site.content = new_hash, new_content
		
		# diff between OLD and NEW
		diff = %x[diff -U 1 --label "#{old_label}" --label "#{new_label}" #{old_site_file.path} #{Conf.file(site.id + '.site')}]
	end
	
	return false if not Filter.accept(diff, site.filters)
	
	Mail.new(
		"[#{Conf[:tag]}] #{site.uri.host} changed",
		"Change at #{site.uri.to_s} - diff follows:\n\n#{diff}"
		).send(site.emails) if Conf.send_mails?
	
	system("logger -t '#{Conf[:tag]}' 'Change at #{site.uri.to_s} (tag #{site.id}) detected'") if Conf[:syslog]
	
	true
end

class MyFormatter
	def call(severity, time, progname, msg)
		"%s: %s\n" % [severity, msg.to_s]
	end
end

# get logger of this program
def logger; $logger end

# create global logger
$logger = Logger.new(STDOUT)
$logger.formatter = MyFormatter.new

# main

Conf.sites.each do |site|
	if checkForUpdate(site)
		logger.warn "#{site.uri.host.to_s} has an update!"
	else
		logger.info "#{site.uri.host.to_s} is unchanged"
	end
end
