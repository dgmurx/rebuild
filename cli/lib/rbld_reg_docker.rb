require 'docker_registry2'
require_relative 'rbld_log'
require_relative 'rbld_utils'

module Rebuild
  module Registry
  module Docker
    extend Rebuild::Utils::Errors

    rebuild_errors \
      EntryNameParsingError: 'Internal registry name parsing failed: %s',
      APIConnectionError: 'Failed to access registry at %s'

    class Entry
      NAME_PFX = 'rbe-'
      TAG_PFX = '-rt-'
      private_constant :NAME_PFX, :TAG_PFX

      def initialize(name = nil, tag = nil, remote = nil)
        @name, @tag, @remote = name, tag, remote

        @url = Rebuild::Utils::FullImageName.new( "#{@remote}/#{NAME_PFX}#{@name}#{TAG_PFX}#{@tag}", \
                                                  'initial' )

        @wildcard = "#{NAME_PFX}#{@name}" + \
                    ( @tag.to_s.empty? ? '' : "#{TAG_PFX}#{@tag}" )
      end

      def self.by_internal_name( int_name )
        m = int_name.match(/^#{NAME_PFX}(.*)#{TAG_PFX}(.*)/)
        raise EntryNameParsingError, int_name unless m
        new( *m.captures )
      end

      attr_reader :name, :tag, :url, :wildcard
    end

    class API
      def initialize(remote, api_accessor = DockerRegistry)
        @remote = remote
        rbld_log.info( "Connecting to registry #{@remote}" )
        begin
          @api = api_accessor.connect("http://#{@remote}")
        rescue StandardError
          raise APIConnectionError, @remote
        end
      end

      def search(name = nil, tag = nil)
        wildcard = Entry.new( name, tag, @remote ).wildcard
        rbld_log.info( "Searching for #{wildcard}" )
        @api.search( wildcard ).map do |internal_name|
          rbld_log.debug( "Found #{internal_name}" )
          parse_entry( internal_name )
        end.compact
      end

      def publish(name, tag, img)
        url = Entry.new( name, tag, @remote ).url
        api_obj = img.api_obj

        api_obj.tag( repo: url.repo, tag: url.tag )

        begin
          rbld_log.info( "Pushing #{url.full}" )
          api_obj.push(nil, :repo_tag => url.full) do |log|
            trace_progress( log )
          end
        ensure
          api_obj.remove( :name => url.full )
        end
      end

      def deploy(name, tag, api_class = ::Docker::Image)
        url = Entry.new( name, tag, @remote ).url

        begin
          rbld_log.info( "Pulling #{url.full}" )
          img = api_class.create(:fromImage => url.full) do |log|
            trace_progress( log )
          end
          yield img
        ensure
          img.remove( :name => url.full ) if img
        end
      end

      private

      def trace_progress(log_item)
        begin
          line = JSON.parse( log_item )["progress"]
          rbld_print.inplace_trace( line ) if line
        rescue
        end
      end

      def parse_entry(internal_name)
        begin
          Entry.by_internal_name( internal_name )
        rescue EntryNameParsingError => msg
          rbld_log.warn( msg )
          return nil
        end
      end
    end
  end
  end
end