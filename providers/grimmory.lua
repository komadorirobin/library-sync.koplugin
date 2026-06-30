return {
    id = "grimmory",
    name = "Grimmory",
    opds_root = "/api/v1/opds",
    api_login = "/api/v1/auth/login",
    api_credentials_separate = true,
    book_api = {
        method = "GET",
        endpoint = "/api/v1/books?stripForListView=false",
        paginated = false,
    },
    author_api = {
        endpoint = "/api/v1/authors",
        paginated = false,
    },
    sync_sources = {
        { endpoint = "/api/v1/opds/shelves", kind = "shelf" },
        { endpoint = "/api/v1/opds/magic-shelves", kind = "magic" },
    },
    author_image_path = function(author_id)
        return "/api/v1/media/author/" .. tostring(author_id) .. "/photo"
    end,
    author_image_token_query = true,
}
