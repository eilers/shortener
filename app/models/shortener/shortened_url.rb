class Shortener::ShortenedUrl
    include ModelShare
    include ActiveModel::Validations
    include NoBrainer::Document::Timestamps

    REGEX_LINK_HAS_PROTOCOL = Regexp.new('\Ahttp:\/\/|\Ahttps:\/\/', Regexp::IGNORECASE)

    field :owner_id,    :type => String
    field :owner_type,  :type => String

    field :url,         :type => Text,      :required => true,  :uniq => {:scope => :category}, :index => true
    field :unique_key,  :type => String,    :required => true,  :uniq => true,                  :index => true

    # a category to help categorize shortened urls
    field :category,    :type => String
    field :use_count,   :type => Integer
    field :expires_at,  :type => Time

    validates :url, presence: true

    # # allows the shortened link to be associated with a user
    # if ActiveRecord::VERSION::MAJOR >= 5
    #     # adds rails 5 compatibility to have nil values as owner
    #     belongs_to :owner, polymorphic: true, optional: true
    # else
    #     belongs_to :owner, polymorphic: true
    # end

    # exclude records in which expiration time is set and expiration time is greater than current time
    scope :unexpired, -> { where( :or => [{:expires_at.defined => false}, {:expires_at.gt => ::Time.current}] ) }

    attr_accessor :custom_key

    # ensure the url starts with it protocol and is normalized
    def self.clean_url(url)

        url = url.to_s.strip
        if url !~ REGEX_LINK_HAS_PROTOCOL && url[0] != '/'
            url = "/#{url}"
        end
        URI.parse(url).normalize.to_s
    end

    # generate a shortened link from a url
    # link to a user if one specified
    # throw an exception if anything goes wrong
    def self.generate!(destination_url, owner: nil, custom_key: nil, expires_at: nil, fresh: false, category: nil)
        # if we get a shortened_url object with a different owner, generate
        # new one for the new owner. Otherwise return same object
        if destination_url.is_a? Shortener::ShortenedUrl
            if destination_url.owner == owner
                destination_url
            else
                generate!(
                    destination_url.url,
                    owner:      owner,
                    custom_key: custom_key,
                    expires_at: expires_at,
                    fresh:      fresh,
                    category:   category
                )
            end
        else
            scope = owner ? owner.shortened_urls : self

            # First check whether the url is used.
            dataset = scope.where(url: clean_url(destination_url), category: category).first
            success = true
            if dataset.nil?
                # URL is not existing. Create a new one
                retries = Shortener.persist_retries
                while (retries > 0)
                    used_key = custom_key || unique_key_candidate
                    dataset = scope.new(url: clean_url(destination_url), category: category, unique_key: used_key, expires_at: expires_at)
                    success = dataset.save

                    retries -= 1
                    break if success
                end
            end

            fail "Unable to create short url " if dataset.nil? || !success
            dataset
        end
    end

    # return shortened url on success, nil on failure
    def self.generate(destination_url, owner: nil, custom_key: nil, expires_at: nil, fresh: false, category: nil)
        begin
            generate!(
                destination_url,
                owner: owner,
                custom_key: custom_key,
                expires_at: expires_at,
                fresh: fresh,
                category: category
            )
        rescue => e
            Rails.logger.info e
            nil
        end
    end

    def self.extract_token(token_str)
        # only use the leading valid characters
        # escape to ensure custom charsets with protected chars do not fail
        /^([#{Regexp.escape(Shortener.key_chars.join)}]*).*/.match(token_str)[1]
    end

    def self.fetch_with_token(token: nil, additional_params: {}, track: true)
        shortened_url = ::Shortener::ShortenedUrl.unexpired.where(unique_key: token).first

        url = if shortened_url
            shortened_url.increment_usage_count if track
            merge_params_to_url(url: shortened_url.url, params: additional_params)
        else
            Shortener.default_redirect || '/'
        end

        { url: url, shortened_url: shortened_url }
    end

    def self.merge_params_to_url(url: nil, params: {})
        if params.respond_to?(:permit!)
            params = params.permit!.to_h.with_indifferent_access.except!(:id, :action, :controller)
        end

        if Shortener.subdomain
            params.try(:except!, :subdomain) if params[:subdomain] == Shortener.subdomain
        end

        if params.present?
            uri = URI.parse(url)
            existing_params = Rack::Utils.parse_nested_query(uri.query)
            uri.query       = existing_params.with_indifferent_access.merge(params).to_query
            url = uri.to_s
        end

        url
    end

    def increment_usage_count
        self.queue_atomic do
            self.use_count += 1
        end
        self.save!
    end

    def to_param
        unique_key
    end

    private

    def self.unique_key_candidate
        charset = ::Shortener.key_chars
        (0...::Shortener.unique_key_length).map{ charset[rand(charset.size)] }.join
    end
end
