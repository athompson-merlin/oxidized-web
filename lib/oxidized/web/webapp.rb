require 'sinatra/base'
require 'sinatra/json'
require 'sinatra/url_for'
require 'tilt/haml'
require 'sass'
require 'oxidized/web/mig'
require 'htmlentities'
require 'charlock_holmes'
module Oxidized
  module API
    class WebApp < Sinatra::Base
      helpers Sinatra::UrlForHelper
      set :public_folder, proc { File.join(root, 'public') }

      get '/' do
        redirect url_for('/nodes')
      end

      get '/nodes/:filter/:value.?:format?' do
        @data = nodes.list.select do |node|
          next unless node[params[:filter].to_sym] == params[:value]

          node[:status] = 'never'
          node[:time]   = 'never'
          node[:group]  = 'default' unless node[:group]
          if node[:last]
            node[:status] = node[:last][:status]
            node[:time]   = node[:last][:end]
          end
          node
        end
        out :nodes
      end

      get '/nodes.?:format?' do
        @data = nodes.list.map do |node|
          node[:status] = 'never'
          node[:time]   = 'never'
          node[:group]  = 'default' unless node[:group]
          if node[:last]
            node[:status] = node[:last][:status]
            node[:time]   = node[:last][:end]
          end
          node
        end
        out :nodes
      end

      post '/nodes/conf_search.?:format?' do
        @to_research = Regexp.new params[:search_in_conf_textbox]
        nodes_list = nodes.list.map
        @nodes_match = []
        nodes_list.each do |n|
          node, @json = route_parse n[:name]
          config = nodes.fetch node, n[:group]
          @nodes_match.push({ node: n[:name], full_name: n[:full_name] }) if config[@to_research]
        end
        @data = @nodes_match
        out :conf_search
      end

      get '/nodes/stats.?:format?' do
        @data = {}
        nodes.each do |node|
          @data[node.name] = node.stats
        end
        out :stats
      end

      get '/reload.?:format?' do
        node = params[:node]
        node ? (nodes.load node) : nodes.load
        @data = node ? "reloaded #{node}" : 'reloaded list of nodes'
        out
      end

      get '/node/fetch/:node' do
        begin
          node, @json = route_parse :node
          @data = nodes.fetch node, nil
        rescue NodeNotFound => e
          @data = e.message
        end
        out :text
      end

      get '/node/fetch/:group/:node' do
        node, @json = route_parse :node
        @data = nodes.fetch node, params[:group]
        out :text
      end

      get '/node/next/?:group?/:node' do
        node, @json = route_parse :node
        begin
          nodes.next node
        rescue NodeNotFound => e
          @data = e.message
        end
        redirect url_for('/nodes') unless @json
        @data = 'ok'
        out
      end

      # use this to attach author/email/message to commit
      put '/node/next/?:group?/:node' do
        node, @json = route_parse :node
        opt = JSON.load request.body.read
        nodes.next node, opt
        redirect url_for('/nodes') unless @json
        @data = 'ok'
        out
      end

      get '/node/show/:node' do
        node, @json = route_parse :node
        @data = nodes.show node
        out :node
      end

      # redirect to the web page for rancid - oxidized migration
      get '/migration' do
        out :migration
      end

      # get the files send
      post '/migration' do
        number = params[:number].to_i
        cloginrc_file = params['cloginrc'][:tempfile]
        path_new_file = params['path_new_file']

        router_db_files = []

        i = 1
        while i <= number
          router_db_files.push({ file: params["file#{i}"][:tempfile], group: params["group#{i}"] })
          i += 1
        end

        migration = Mig.new(router_db_files, cloginrc_file, path_new_file)
        migration.go_rancid_migration
        redirect url_for('//nodes')
      end

      get '/css/*.css' do
        sass :"sass/#{params[:splat].first}"
      end

      # show the lists of versions for a node
      get '/node/version.?:format?' do
        @data = nil
        @group = nil
        @node = nil
        node_full = params[:node_full]
        if node_full.include? '/'
          node_full = node_full.split('/')
          @group = node_full[0]
          @node = node_full[1]
          @data = nodes.version @node, @group
        else
          @node = node_full
          @data = nodes.version @node, nil
        end
        out :versions
      end

      # show the blob of a version
      get '/node/version/view.?:format?' do
        node, @json = route_parse :node
        @info = {
          node: node,
          group: params[:group],
          oid: params[:oid],
          date: params[:date],
          num: params[:num]
        }

        the_data = nodes.get_version node, @info[:group], @info[:oid]
        detection = ::CharlockHolmes::EncodingDetector.detect(the_data)
        utf8_encoded_content = ::CharlockHolmes::Converter.convert the_data, detection[:encoding], 'UTF-8'
        @data = HTMLEntities.new.encode(utf8_encoded_content)
        out :version
      end

      # show diffs between 2 version
      get '/node/version/diffs' do
        node, @json = route_parse :node
        @data = nil
        @info = { node: node, group: params[:group], oid: params[:oid], date: params[:date], num: params[:num], num2: (params[:num].to_i - 1) }
        group = nil
        group = @info[:group] if @info[:group] != ''
        @oids_dates = nodes.version node, group
        if params[:oid2]
          @info[:oid2] = params[:oid2]
          oid2 = nil
          num = @oids_dates.count + 1
          @oids_dates.each do |x|
            num -= 1
            next unless x[:oid].to_s == params[:oid2]

            oid2 = x[:oid]
            @info[:num2] = num
            break
          end
          @data = nodes.get_diff node, @info[:group], @info[:oid], oid2
        else
          @data = nodes.get_diff node, @info[:group], @info[:oid], nil
        end
        @stat = %w[null null]
        if @data != 'no diffs' && !@data.nil?
          @stat = @data[:stat]
          @data = @data[:patch]
        else
          @data = 'no available'
        end
        @diff = diff_view @data
        out :diffs
      end

      # used for diff between 2 distant commit
      post '/node/version/diffs' do
        redirect url_for("/node/version/diffs?node=#{params[:node]}&group=#{params[:group]}&oid=#{params[:oid]}&date=#{params[:date]}&num=#{params[:num]}&oid2=#{params[:oid2]}")
      end

      private

      def out(template = :text)
        if @json || (params[:format] == 'json')
          if @data.is_a?(String)
            json @data.lines
          else
            json @data
          end
        elsif (template == :text) || (params[:format] == 'text')
          content_type :text
          @data
        else
          haml template, layout: true
        end
      end

      def nodes
        settings.nodes
      end

      def route_parse(param)
        json = false
        e = if param.respond_to?(:to_str)
              param.split '.'
            else
              params[param].split '.'
            end
        if e.last == 'json'
          e.pop
          json = true
        end
        [e.join('.'), json]
      end

      # give the time enlapsed between now and a date
      def time_from_now(date)
        if date
          # if the + or - is missing, insert +
          date.insert(21, '+') unless date =~ /[-+]/
          date = DateTime.parse date
          now = DateTime.now.new_offset(0)
          t = ((now - date) * 24 * 60 * 60).to_i
          mm, ss = t.divmod(60)
          hh, mm = mm.divmod(60)
          dd, hh = hh.divmod(24)
          date = if dd.positive?
                   "#{dd} days #{hh} hours ago"
                 elsif hh.positive?
                   "#{hh} hours #{mm} min ago"
                 else
                   "#{mm} min #{ss} sec ago"
                 end
        end
        date
      end

      # method the give diffs in separate view (the old and the new) as in github
      def diff_view(diff)
        old_diff = []
        new_diff = []

        detection = ::CharlockHolmes::EncodingDetector.detect(diff)
        utf8_encoded_content = ::CharlockHolmes::Converter.convert diff, detection[:encoding], 'UTF-8'
        HTMLEntities.new.encode(utf8_encoded_content).each_line do |line|
          if /^\+/.match(line)
            new_diff.push(line)
          elsif /^-/.match(line)
            old_diff.push(line)
          else
            new_diff.push(line)
            old_diff.push(line)
          end
        end

        length_o = old_diff.count
        length_n = new_diff.count
        (0..[length_o, length_n].max).each do |i|
          break if i > [length_o, length_n].min

          if /^-.*/.match(old_diff[i]) && !/^\+.*/.match(new_diff[i])
            # tag removed latter to add color syntax
            # ugly way to avoid asymmetry if at display the line takes 2 line on the screen
            insert = "&nbsp;\n"
            new_diff.insert(i, insert)
            length_n += 1
          elsif !/^-.*/.match(old_diff[i]) && /^\+.*/.match(new_diff[i])
            insert = "&nbsp;\n"
            old_diff.insert(i, insert)
            length_o += 1
          end
        end
        { old_diff: old_diff, new_diff: new_diff }
      end
    end
  end
end
