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
				:range => (begin_range..end_range)
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
end

mp = MasterPlanner.new({
	:city => 'newyork',
	:credentials => JSON.parse(IO.read('credentials.json'))
})

# mp.login
mp.preprocess_events_list