require 'net/http'
require 'uri'
require 'date'
require 'nokogiri'
require 'json'

class MasterPlanner

	@@date_format = '%m/%d/%Y'
	@@events_body_selector = '#contentright > div[class^="evtList"]'
	@@events_date_selector = 'div.evtList_Date'
	@@event_selector = 'div.evtList_Evt'

	def initialize(options)
		@credentials = options[:credentials]
		@city = options[:city]
		@session_cookie = ''

		setup_endpoints
	end

	def setup_endpoints
		@login_endpoint = {
			:url => "http://masterplanneronline.com/Handlers/Login.ashx?region=#{@city}",
			:method => 'POST',
			:form_data => @credentials
		}

		@calendar_endpoint = {
			:url => "http://masterplanneronline.com/#{@city}",
			:method => 'POST',
			:form_data => {
				'__EVENTTARGET' => '',
				'__EVENTARGUMENT' => '',
				'ctl00$ddSearchType' => -1,
				'ctl00$ddDateRange' => 'Custom',
				'ctl00$txtDateFrom' => Date.today.strftime(@@date_format),
				'ctl00$txtDateTo' => (Date.today >> 12).strftime(@@date_format)
			}
		}
	end

	def login
		uri = URI @login_endpoint[:url]
		http = Net::HTTP.new uri.host, uri.port
		req = Net::HTTP::Post.new uri.request_uri
		req.set_form_data @credentials
		puts ">> Attempting login..."

		res = http.request req
		if res.code == "200"
			puts ">> Login successful"
		else
			puts ">> Login error (#{res.code})"
			puts res.body.inspect
		end

		@session_cookie = res.response['set-cookie'].split('; ').first
	end	

	def fetch_events_body
		uri = URI @calendar_endpoint[:url]
		http = Net::HTTP.new uri.host, uri.port
		req = Net::HTTP::Post.new uri.request_uri
		req['Cookie'] = @session_cookie
		req.set_form_data @calendar_endpoint[:form_data]
		
		start_time = DateTime.now
		puts ">> Beginning events request"
		res = http.request req
		end_time = DateTime.now
		time_difference = ((end_time - start_time) * 24 * 60 * 60).to_i
		puts ">> Completed events request in #{time_difference}s"
		
		return res.body
	end

	def process_events_body
		cache_location = 'mp.cache'
		if File.exist? cache_location
			body = IO.read(cache_location)
		else
			body = fetch_events_body
		end

		return Nokogiri::HTML(body).css(@@events_body_selector)
	end

	def preprocess_events_list
		events_body = process_events_body

		event_date_nodes = events_body.select { |node|
			node.attr('class').split(' ').first == @@events_date_selector.split('.').last
		}

		event_date_ranges = event_date_nodes.each_with_index.map { |node, index|
			begin_range = events_body.index(node) + 1
			end_range = 
				if index == event_date_nodes.length - 1
					events_body.length - 1
				else
					events_body.index(event_date_nodes[index + 1])
				end
			{
				:date => Date.parse(node.at('h2').text),
				:range => (begin_range...end_range)
			}
		}

		events = []
		event_date_ranges.each do |event_date_range|
			event_date_range[:range].each do |event_node_index|
				event = {}
				event[:node] = events_body[event_node_index]
				event[:date] = event_date_range[:date]
				events.push event
			end
		end

		return events
	end

	def process_events_list
		processed_events = []
		events = preprocess_events_list
		events.each do |event|
			processed_event = parse_event_node event[:node]
			processed_event[:date] = event[:date]
			processed_events.push processed_event
		end

		processed_events

	end

	def parse_mp_block_text(text)
		parsed = text.gsub("\r\n",'').squeeze(" ").split(/\u00A0{2}/).map! { |field|
			field.strip.gsub(/\.$/,'')
		}

		parsed.reject! { |line|
			line.empty? # Remove empty lines
		}
		parsed
	end


	def parse_event_node(node)
		event = {}

		######## HEADER FIELDS ########

		# Preparation Steps: None Required

		# (1) Organization Name
		# Required: True
		# Type: String
		# Strategy: Selector

		event[:organization] = node.at('.evtList_Evt_Head h3').text.strip

		# (2) Event Name
		# Required: True
		# Type: String
		# Strategy: Selector

		event[:name] = node.at('.evtList_Evt_Info .EvtTitle').text.strip
		
		# (3) MasterPlanner Description
		# Description: The full description block to assist with debugging and error correction
		# Required: True
		# Type: String
		# Strategy: Selector

		# event[:mp_description] = node.at('.evtList_Evt_Info').text

		######## DESCRIPTION BLOCK ########

		# Preparation Steps:
		# 	- Get text node (3rd child)
		# 	- Delete newlines
		# 	- Remove multiple spacing
		# 	- Split into array using regex for two consecutive non-breaking spaces using its unicode char
		# 	- Remap array to strip leading and trailing whitespace for each extracted property as well as trailing

		mp_description_array = parse_mp_block_text node.at('.evtList_Evt_Info').children[2].text
		mp_extra_array = parse_mp_block_text node.at('.evtList_ExtInfo').text

		event_fields_array = mp_description_array | mp_extra_array	

		matches, unmatched = match_fields event_fields_array, {
			:start_time => {
				:regex => /\A\d?[0-2]?:[0-5][0-9] (am|pm)\z/,
				:unprefixed => true
			},
			:attire => {
				:regex => / attire$/
			},
			:invitation_only => {
				:regex => /^Invitation only$/,
				:boolean => true
			},
			:speakers => {
				:regex => /^Speaker\(s\): /,
				:array => true
			},
			:honorees => {
				:regex => /^Honoring /,
				:array => true
			},
			:chairs => {
				:regex => /^Chaired by /,
				:array => true
			},
			:co_chairs => {
				:regex => /^Co-chaired by /,
				:array => true
			},
			:hosts => {
				:regex => /^Hosted by /,
				:array => true
			},
			:ticket_price => {
				:regex => /^Tickets from \$/,
				:number => true
			},
			:table_price => {
				:regex => /^Tables from \$/,
				:number => true
			},
			:contact_name => {
				:regex => /^Contact: /
			},
			:contact_phone => {
				# Match numbers in format (999){whitespace or nbsp}999-9999
				:regex => /^\(\d{3}\)(\s|\u00a0)\d{3}-\d{4}$/,
				:unprefixed => true
			}, 
			:website => {
				:regex => /^Event web address: /
			},
			:address => {
				:regex => /^Event address: /
			}
		}

		event.merge! matches
		city = unmatched.grep(/^(New York|New York City|Brooklyn|Bronx)$/).first
		if city
			venue = unmatched[unmatched.index(city) - 1]
			unmatched.delete city
			unmatched.delete venue
			event[:city] = city
			event[:venue] = venue
		end
		if unmatched.any?
			puts "Matched:"
			puts event.inspect
			puts "Unmatched:"
			puts unmatched.inspect
		end
		
		return event
	end

	def match_fields(source_array, matcher_hash)
		matches = {}
		unmatched = source_array
		matcher_hash.each do |property, params|
			match = source_array.grep params[:regex]
			if match.length >= 2
				puts "Matched #{match.length} times for #{property}"
				puts match
			elsif match.empty?
				# puts "No match for #{property}"
			else
				match = match.first
				unmatched.delete match
				match.gsub!(params[:regex], '') unless params[:unprefixed]
				if params[:array]
					matches[property] = match.split ', '
				elsif params[:boolean]
					matches[property] = true
				elsif params[:number]
					matches[property] = match.gsub(',','').to_i
				else
					matches[property] = match
				end
			end
		end
		return matches, unmatched
	end

end

mp = MasterPlanner.new({
	:city => 'newyork',
	:credentials => JSON.parse(IO.read('credentials.json'))
})

# mp.login
sample_node = Nokogiri::HTML IO.read('sample-node.html')
mp.process_events_list