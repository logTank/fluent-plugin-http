#
# Extended version of fluent's core http plugin
# original: https://github.com/fluent/fluentd/blob/master/lib/fluent/plugin/in_http.rb
#

module Fluent
  class LogtankHttpInput < Input
    Plugin.register_input('logtank_http', self)

    include DetachMultiProcessMixin

    require 'http/parser'

    def initialize
      require 'webrick/httputils'
      require 'uri'
      super
    end

    EMPTY_GIF_IMAGE = "GIF89a\u0001\u0000\u0001\u0000\x80\xFF\u0000\xFF\xFF\xFF\u0000\u0000\u0000,\u0000\u0000\u0000\u0000\u0001\u0000\u0001\u0000\u0000\u0002\u0002D\u0001\u0000;".force_encoding("UTF-8")

    config_param :port, :integer, :default => 9880
    config_param :bind, :string, :default => '0.0.0.0'
    config_param :body_size_limit, :size, :default => 32*1024*1024  # TODO default
    config_param :keepalive_timeout, :time, :default => 10   # TODO default
    config_param :backlog, :integer, :default => nil
    config_param :add_http_headers, :bool, :default => false
    config_param :add_remote_addr, :bool, :default => false
    config_param :format, :string, :default => 'default'
    config_param :blocking_timeout, :time, :default => 0.5
    config_param :cors_allow_origins, :array, :default => nil
    config_param :respond_with_empty_img, :bool, :default => false

    def configure(conf)
      super

      m = if @format == 'default'
            method(:parse_params_default)
          else
            @parser = Plugin.new_parser(@format)
            @parser.configure(conf)
            method(:parse_params_with_parser)
          end
      (class << self; self; end).module_eval do
        define_method(:parse_params, m)
      end
    end

    class KeepaliveManager < Coolio::TimerWatcher
      def initialize(timeout)
        super(1, true)
        @cons = {}
        @timeout = timeout.to_i
      end

      def add(sock)
        @cons[sock] = sock
      end

      def delete(sock)
        @cons.delete(sock)
      end

      def on_timer
        @cons.each_pair {|sock,val|
          if sock.step_idle > @timeout
            sock.close
          end
        }
      end
    end

    def start
      log.debug "listening http on #{@bind}:#{@port}"
      lsock = TCPServer.new(@bind, @port)

      detach_multi_process do
        super
        @km = KeepaliveManager.new(@keepalive_timeout)
        #@lsock = Coolio::TCPServer.new(@bind, @port, Handler, @km, method(:on_request), @body_size_limit)
        @lsock = Coolio::TCPServer.new(lsock, nil, Handler, @km, method(:on_request),
                                       @body_size_limit, @format, log,
                                       @cors_allow_origins)
        @lsock.listen(@backlog) unless @backlog.nil?

        @loop = Coolio::Loop.new
        @loop.attach(@km)
        @loop.attach(@lsock)

        @thread = Thread.new(&method(:run))
      end
    end

    def shutdown
      @loop.watchers.each {|w| w.detach }
      @loop.stop
      @lsock.close
      @thread.join
    end

    def run
      @loop.run(@blocking_timeout)
    rescue
      log.error "unexpected error", :error=>$!.to_s
      log.error_backtrace
    end

    def on_request(path_info, params)
      begin
        path = path_info[1..-1]  # remove /
        tag = path.split('/').join('.')
        record_time, record = parse_params(params)

        # Skip nil record
        if record.nil?
          if @respond_with_empty_img
            return ["200 OK", {'Content-type'=>'image/gif; charset=utf-8'}, EMPTY_GIF_IMAGE]
          else
            return ["200 OK", {'Content-type'=>'text/plain'}, ""]
          end
        end

        if @add_http_headers
          params.each_pair { |k,v|
            if k.start_with?("HTTP_")
              record[k] = v
            end
          }
        end

        if @add_remote_addr
          record['REMOTE_ADDR'] = params['REMOTE_ADDR']
        end

        time = if param_time = params['time']
                 param_time = param_time.to_i
                 # Engine.now has only second-precision, use Time.now.to_f to get millisecond precision
                 # param_time.zero? ? Engine.now : param_time
                 param_time.zero? ? Time.now.to_f : param_time
               else
                 # Engine.now has only second-precision, use Time.now.to_f to get millisecond precision
                 # record_time.nil? ? Engine.now : record_time
                 record_time.nil? ? Time.now.to_f : record_time
               end
      rescue
        return ["400 Bad Request", {'Content-type'=>'text/plain'}, "400 Bad Request\n#{$!}\n"]
      end

      # TODO server error
      begin
        # Support batched requests
        if record.is_a?(Array)
          mes = MultiEventStream.new
          record.each do |single_record|
            single_time = single_record.delete("time") || time
            mes.add(single_time, single_record)
          end
          router.emit_stream(tag, mes)
        else
          router.emit(tag, time, record)
        end
      rescue
        return ["500 Internal Server Error", {'Content-type'=>'text/plain'}, "500 Internal Server Error\n#{$!}\n"]
      end

      if @respond_with_empty_img
        return ["200 OK", {'Content-type'=>'image/gif; charset=utf-8'}, EMPTY_GIF_IMAGE]
      else
        return ["200 OK", {'Content-type'=>'text/plain'}, ""]
      end
    end

    private

    def parse_params_default(params)
      record = if msgpack = params['msgpack']
                 MessagePack.unpack(msgpack)
               elsif js = params['json']
                 JSON.parse(js)
               else
                 raise "'json' or 'msgpack' parameter is required"
               end
      return nil, record
    end

    EVENT_RECORD_PARAMETER = '_event_record'

    def parse_params_with_parser(params)
      if content = params[EVENT_RECORD_PARAMETER]
        @parser.parse(content) { |time, record|
          raise "Received event is not #{@format}: #{content}" if record.nil?
          return time, record
        }
      else
        raise "'#{EVENT_RECORD_PARAMETER}' parameter is required"
      end
    end

    class Handler < Coolio::Socket
      def initialize(io, km, callback, body_size_limit, format, log, cors_allow_origins)
        super(io)
        @km = km
        @callback = callback
        @body_size_limit = body_size_limit
        @next_close = false
        @format = format
        @log = log
        @cors_allow_origins = cors_allow_origins
        @idle = 0
        @km.add(self)

        @remote_port, @remote_addr = *Socket.unpack_sockaddr_in(io.getpeername) rescue nil
      end

      def step_idle
        @idle += 1
      end

      def on_close
        @km.delete(self)
      end

      def on_connect
        @parser = Http::Parser.new(self)
      end

      def on_read(data)
        @idle = 0
        @parser << data
      rescue
        @log.warn "unexpected error", :error=>$!.to_s
        @log.warn_backtrace
        close
      end

      def on_message_begin
        @body = ''
      end

      def on_headers_complete(headers)

        expect = nil
        size = nil

        if @parser.http_version == [1, 1]
          @keep_alive = true
        else
          @keep_alive = false
        end
        @env = {}
        @content_type = ""
        headers.each_pair {|k,v|
          @env["HTTP_#{k.gsub('-','_').upcase}"] = v
          case k
          when /Expect/i
            expect = v
          when /Content-Length/i
            size = v.to_i
          when /Content-Type/i
            @content_type = v
          when /Connection/i
            if v =~ /close/i
              @keep_alive = false
            elsif v =~ /Keep-alive/i
              @keep_alive = true
            end
          when /Origin/i
            @origin  = v
          when /Access-Control-Request-Method/i
            @requestMethod = v
          when /Access-Control-Request-Headers/i
            @requestHeaders = v
          end
        }
        if expect
          if expect == '100-continue'
            if !size || size < @body_size_limit
              send_response_nobody("100 Continue", {})
            else
              send_response_and_close("413 Request Entity Too Large", {}, "Too large")
            end
          else
            send_response_and_close("417 Expectation Failed", {}, "")
          end
        elsif @parser.http_method.upcase == 'OPTIONS'
          send_response_and_close("200 OK", {}, "")
        end
      end

      def on_body(chunk)
        if @body.bytesize + chunk.bytesize > @body_size_limit
          unless closing?
            send_response_and_close("413 Request Entity Too Large", {}, "Too large")
          end
          return
        end
        @body << chunk
      end

      def on_message_complete
        return if closing?

        # CORS check
        # ==========
        # For every incoming request, we check if we have some CORS
        # restrictions and white listed origins through @cors_allow_origins.
        unless @cors_allow_origins.nil?
          unless @cors_allow_origins.include?(@origin)
            send_response_and_close("403 Forbidden", {'Connection' => 'close'}, "")
            return
          end
        end

        @env['REMOTE_ADDR'] = @remote_addr if @remote_addr

        uri = URI.parse(@parser.request_url)
        params = WEBrick::HTTPUtils.parse_query(uri.query)

        if @format != 'default'
          params[EVENT_RECORD_PARAMETER] = @body
        elsif @content_type =~ /^application\/x-www-form-urlencoded/
          params.update WEBrick::HTTPUtils.parse_query(@body)
        elsif @content_type =~ /^multipart\/form-data; boundary=(.+)/
          boundary = WEBrick::HTTPUtils.dequote($1)
          params.update WEBrick::HTTPUtils.parse_form_data(@body, boundary)
        elsif @content_type =~ /^application\/json/
          params['json'] = @body
        end
        path_info = uri.path

        params.merge!(@env)
        @env.clear

        code, header, body = *@callback.call(path_info, params)
        body = body.to_s

        if @keep_alive
          header['Connection'] = 'Keep-Alive'
          send_response(code, header, body)
        else
          send_response_and_close(code, header, body)
        end
      end

      def on_write_complete
        close if @next_close
      end

      def send_response_and_close(code, header, body)
        send_response(code, header, body)
        @next_close = true
      end

      def closing?
        @next_close
      end

      def send_response(code, header, body)
        header['Content-length'] ||= body.bytesize
        header['Content-type'] ||= 'text/plain'
        header['Access-Control-Allow-Origin'] ||= '*'
        (header['Access-Control-Allow-Methods'] ||= @requestMethod) if @requestMethod
        (header['Access-Control-Allow-Headers'] ||= @requestHeaders) if @requestHeaders

        data = %[HTTP/1.1 #{code}\r\n]
        header.each_pair {|k,v|
          data << "#{k}: #{v}\r\n"
        }
        data << "\r\n"
        write data

        write body
      end

      def send_response_nobody(code, header)
        data = %[HTTP/1.1 #{code}\r\n]
        header.each_pair {|k,v|
          data << "#{k}: #{v}\r\n"
        }
        data << "\r\n"
        write data
      end
    end
  end
end