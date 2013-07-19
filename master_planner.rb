require 'net/http'
require 'uri'
require 'date'
require 'nokogiri'

class MasterPlanner

	@@date_format = '%m/%d/%Y'
	@@events_selector = '.evtList_Evt, .evtList_Date'

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
		res = http.request req

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

	end

	def process_events_list

	end
end

mp = MasterPlanner.new({
	:city => 'newyork',
	:credentials => JSON.parse(IO.read('credentials.json'))
})

mp.login