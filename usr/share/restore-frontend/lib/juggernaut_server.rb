#  Copyright (c) 2006 Alexander MacCaw
#  Copyright (c) 2006 Michael Schuerig
#  
#  Permission is hereby granted, free of charge, to any person obtaining
#  a copy of this software and associated documentation files (the
#  "Software"), to deal in the Software without restriction, including
#  without limitation the rights to use, copy, modify, merge, publish,
#  distribute, sublicense, and/or sell copies of the Software, and to
#  permit persons to whom the Software is furnished to do so, subject to
#  the following conditions:
#  
#  The above copyright notice and this permission notice shall be
#  included in all copies or substantial portions of the Software.
#  
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
#  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
#  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
#  LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
#  OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
#  WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#++

require 'eventmachine'
require 'json'
require 'monitor'
require 'yaml'
require 'logger'
require 'open-uri'
require 'erb'


module Juggernaut # :nodoc:
  begin
    CONFIG = YAML::load(ERB.new(IO.read("#{CONFIG_PATH}/juggernaut.yml")).result).freeze
  rescue
    $stderr.write("[!] Juggernaut's push_server can't find its config file, try to reinstall Juggernaut: rake juggernaut:reinstall\n")
    exit -1
  end

  POLICY_FILE = <<EOF
<cross-domain-policy>
<allow-access-from domain="*" to-ports="#{Juggernaut::CONFIG['PUSH_PORT']}" />
</cross-domain-policy>
EOF

  POLICY_REQUEST = '<policy-file-request/>'
  
  class Debug
    def self.send msg
      puts msg if Juggernaut::CONFIG['LOG_SCROLL'] == true
      $LOG.info msg if $LOG
    end
    def self.warn msg
      puts msg.capitalize
      $LOG.warn msg if $LOG
    end
  end
  
  class CheckSession
    def self.check(ses_id, channels, unique_id = nil)
      return false unless CONFIG['LOGIN_GET_URL']
      # Only check session if it says in the log file
      #Open http to logon function 
      begin
        query_string = []
        channels.each do |c|
          query_string << 'channels[]=' + c
        end
        (query_string << 'unique_id=' + unique_id) if unique_id and unique_id != 'null'
        open(CONFIG['LOGIN_GET_URL'] + '?' + query_string.join('&'),"User-Agent" => "Ruby/#{RUBY_VERSION}","Cookie" => (CONFIG['SESSION_ID'] || '_session_id') + "=#{ses_id}")
      rescue
        Debug.send "Login post Failed"
        return true
      end
      false
    rescue
      #Just to be on the safe side
      return true
    end
  end

  class Channels < Monitor
    def initialize
      @channels = {}
      super
    end
    
    def subscribe(channel_name, connection)
      synchronize do
        channel = (@channels[channel_name] ||= Channel.new(channel_name))
        channel.subscribe(connection)
        ##Debug.send "Channels after new subscription: #{@channels.keys.inspect}"
      end
    end
     
    def unsubscribe(channel_name, connection)
      synchronize do
        if channel = @channels[channel_name]
          channel.unsubscribe(connection)
        end
      end
    end

    def broadcast(channel_name, data)
      channel = nil
      synchronize do
        channel = @channels[channel_name]
      end
      channel.broadcast(data) if channel
      Debug.send  "No such channel: #{channel_name}" if channel.nil?
    end
  end

  class Channel < Monitor
    def initialize(name)
      @name = name
      @subscribers = []
      super()
    end
    
    def subscribe(connection)
      @subscribers << connection unless @subscribers.include?(connection)
    end
    
    def unsubscribe(connection)
      @subscribers.delete connection
    end
    
    def broadcast(data)
      Debug.send  "Broadcasting to channel: #{@name}"
      receivers = nil
      synchronize do
        receivers = @subscribers.dup
      end
      receivers.each do |receiver|
        begin
          receiver.send_data(data)
        rescue
          @subscribers.delete receiver
          Debug.warn $! ### FIXME
        end    
      end
    end
  end


  module PushServer
  
    def receive_data(data)
      ##Debug.send  "Received: #{data}"
      @line_buffer << data
      Debug.send "Starting to parse line buffer"
      if ["\0", "\n", "\r"].include?(data[-1, 1])
        #Debug.send "gonna dispatch_request"
        dispatch_request
      else
        Debug.send "nope, didn't dispatch request"
      end
    end

    def post_init
      Debug.send "Connection established"
      @@channels ||= Channels.new
      @line_buffer = ''
      @@connections ||= {} #stored connections hash
      @@mapped ||= {}
      @ses_id = '' #ses_id
    end
    
    def unbind
      Debug.send "Connection closed"
      dispatch_request
    end
    
    def dispatch_request
      Debug.send "Starting to parse request"
      request = parse_request
      ##Debug.send  "Handling request: #{request.inspect}"
      return unless request
      if request['broadcast'] == 1
        broadcast(request)
      else
        unless request['function']
          subscribe(request)
        else
          case request['function']
          when "sendTo"
            Debug.send "Sending solo stream to individual client #{request['to']}"
            begin
              if @@connections[request['to']]
                @@connections[request['to']].send_data(request['message'] + "\0")
              end
            rescue
              Debug.send "The send_to failed."
            end
          when "addChannel":
            Debug.send "Adding channels #{request['channels'].inspect} to #{request['id']}"
            if @@connections[request['id']]
              request['channels'].each do |channel_name|
                @@channels.subscribe(channel_name, @@connections[request['id']])
                Debug.send "adding #{channel_name} to {request['id']}"
              end
            end
          when "removeChannel"
            Debug.send "Removing channels #{request['channels'].inspect} from #{request['id']}"
            request['channels'].each do |channel_name|
              @@channels.unsubscribe(channel_name, @@connections[request['id']])
            end
          when "sesToUniqueId"
            #TODO: Add a function to allow a change or addition of a unique identifier for a connection. Takes
            #in a ses_id and a u_id and adds it to the correct connection.
          end
        end
      end
    end

    def broadcast(request)
      if request['secret'] != CONFIG['SECRET']
	Debug.warn "Unauthorized broadcast attempt"
        return
      end
      Debug.send  "Broadcasting #{request['message']}"
      request['channels'].each do |channel_name|
        @@channels.broadcast(channel_name, request['message'] + "\0")
      end
    end

    def subscribe(request)
      if CheckSession.check(request['ses_id'], request['channels'], request['unique_id'])
        Debug.warn "Unauthorized connection attempt"
        return
      end
      Debug.send  "Subscribing to channels #{request['channels']}"
      request['channels'].each do |channel_name|
        @@channels.subscribe(channel_name, self)
      end
      @ses_id = request['ses_id']
      if request['unique_id'] == "null"
        Debug.send "Registered connection with a session id of #{@ses_id}"
        @@connections[@ses_id] = self
        @@mapped[@ses_id] = @ses_id
      else
        Debug.send "Registered connection with a unique id of #{request['unique_id']}"
        @@connections[request['unique_id']] = self
        @@mapped[@ses_id] = request['unique_id']
      end
      #@@unique_mapper[@ses_id] = request['unique_id']
      #Debug.send @@unique_mapper[@ses_id].inspect
    end

    def parse_request
      Debug.send "Line buffer: [#{@line_buffer}]"
      buf_size = @line_buffer.length
      @line_buffer.strip!
      request = nil
      unless @line_buffer.empty?
        @line_buffer.sub!("\000", '') #gets around problem with JSON parsing client request
        begin
          if @line_buffer == POLICY_REQUEST
            send_data POLICY_FILE + "\0"
            Debug.send "Crossdomain policy request"
            return nil
          end
          request = JSON.parse(@line_buffer)
          @line_buffer = ''
        rescue => e
          $LOG.error "Failed to parse [#{@line_buffer}]: #{e}"
        end
      end
      #Took forever to find this. Apparently when using a domain, and not an IP or localhost domain when a client
      #connects it sends two requests. Both mimic the logoff signature. The one difference between the two was a 
      # \n line break. Below makes sure the size of the buffer is in fact 0, thus a logoff is triggered.
      #UPDATE: I found out why this is. In the actionscript file for the swf, it sends a "\n" via the socket connection
      #I didn't remove it because I don't kno what it's for. If it aint broke...
      #Debug.send "["+@line_buffer+"]"
      if request.nil? and buf_size == 0
        unless @@connections[@@mapped[@ses_id]].nil?
          Debug.send "User #{@ses_id} Logged off"
          #Debug.send @@connections.inspect
          begin
            @@connections.delete(@@mapped[@ses_id]) #Deletes user's connection from @@connections
            open(CONFIG['LOGOUT_GET_URL'],"User-Agent" => "Ruby/#{RUBY_VERSION}","Cookie" => (CONFIG['SESSION_ID'] || '_session_id') + "=#{@ses_id}") if CONFIG['LOGOUT_GET_URL']
          rescue
            Debug.send "Logout post Failed"
          end
        end
      end
      request
    end

  end
end


