class User
    include ::NoBrainer::ModelShare
    include ActiveModel::Validations
    include NoBrainer::Document::Timestamps

    has_shortened_urls
end
