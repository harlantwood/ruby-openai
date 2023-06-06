require "amazing_print"

module OpenAI
  module HTTP
    def get(path:)
      to_json(conn.get(uri(path: path)) do |req|
        req.headers = headers
      end&.body)
    end

    def json_post(path:, parameters:)
      to_json(conn.post(uri(path: path)) do |req|
        if parameters[:stream].respond_to?(:call)
          req.options.on_data = to_json_stream(user_proc: parameters[:stream])
          parameters[:stream] = true # Necessary to tell OpenAI to stream.
        elsif parameters[:stream]
          raise ArgumentError, "The stream parameter must be a Proc or have a #call method"
        end

        req.headers = headers
        req.body = parameters.to_json
      end&.body)
    end

    def multipart_post(path:, parameters: nil)
      to_json(conn(multipart: true).post(uri(path: path)) do |req|
        req.headers = headers.merge({ "Content-Type" => "multipart/form-data" })
        req.body = multipart_parameters(parameters)
      end&.body)
    end

    def delete(path:)
      to_json(conn.delete(uri(path: path)) do |req|
        req.headers = headers
      end&.body)
    end

    private

    def to_json(string)
      return unless string

      JSON.parse(string)
    rescue JSON::ParserError
      # Convert a multiline string of JSON objects to a JSON array.
      JSON.parse(string.gsub("}\n{", "},{").prepend("[").concat("]"))
    end

    # Given a proc, returns an outer proc that can be used to iterate over a JSON stream of chunks.
    # For each chunk, the inner user_proc is called giving it the JSON object. The JSON object could
    # be a data object or an error object as described in the OpenAI API documentation.
    #
    # If the JSON object for a given data or error message is invalid, it is ignored.
    #
    # @param user_proc [Proc] The inner proc to call for each JSON object in the chunk.
    # @return [Proc] An outer proc that iterates over a raw stream, converting it to JSON.
    #
    # ACUAL ERROR RESPONSE - full chunk:
    # {
    #     "error": {
    #         "message": "",
    #         "type": "invalid_request_error",
    #         "param": null,
    #         "code": "invalid_api_key"
    #     }
    # }
    def to_json_stream(user_proc:)
      proc do |chunk, _|
        ap "chunk:"
        puts chunk

        # lines = chunk.split("\n").map(&:strip).reject(&:empty?)
        # results = lines.map do |line|
        #   match = line.match(/^(data|error): *(\{.+\})/i)
        #   result_type = match[1]
        #   result_json = match[2]
        #   result = JSON.parse(result_json)
        #   result.merge!("result_type" => result_type)
        #   ap "result:"
        #   ap result
        #   user_proc.call(result)
        # rescue JSON::ParserError
        #   # Ignore invalid JSON.
        # end.compact

        # result = {
        #   "result_type" => "invalid_json",
        #   "chunk" => chunk,
        #   "sub_chunk" => result_json
        # }
        # user_proc.call(result)

        results = chunk.scan(/^(data|error): *(\{.+\})/i)
        if results.length > 0
          results.each do |result_type, result_json|
            result = JSON.parse(result_json)
            result.merge!("result_type" => result_type)
            ap "result:"
            ap result
            user_proc.call(result)
          rescue JSON::ParserError
            # Ignore invalid JSON.
          end
        elsif !chunk.match(/^(data|error):/i)
          result = JSON.parse(chunk)
          result_type = result["error"] ? "error" : "unkown"
          result.merge!("result_type" => result_type)
          user_proc.call(result)
        end
      rescue JSON::ParserError
        result = {
          "result_type" => "unkown",
          "chunk" => chunk
        }
        user_proc.call(result)
      end
    end

    def conn(multipart: false)
      Faraday.new do |f|
        f.options[:timeout] = OpenAI.configuration.request_timeout
        f.request(:multipart) if multipart
      end
    end

    def uri(path:)
      OpenAI.configuration.uri_base + OpenAI.configuration.api_version + path
    end

    def headers
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{OpenAI.configuration.access_token}",
        "OpenAI-Organization" => OpenAI.configuration.organization_id
      }
    end

    def multipart_parameters(parameters)
      parameters&.transform_values do |value|
        next value unless value.is_a?(File)

        # Doesn't seem like OpenAI need mime_type yet, so not worth
        # the library to figure this out. Hence the empty string
        # as the second argument.
        Faraday::UploadIO.new(value, "", value.path)
      end
    end
  end
end
