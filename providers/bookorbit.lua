return {
    id = "bookorbit",
    name = "BookOrbit",
    opds_root = "/api/v1/opds",
    api_login = "/api/v1/auth/login",
    api_credentials_separate = true,
    api_fallback_to_opds_credentials = true,
    book_api = {
        method = "POST",
        endpoint = "/api/v1/books/query",
        paginated = true,
        page_size = 200,
    },
    author_api = {
        endpoint = "/api/v1/authors?hasPhoto=true&sort=name&order=asc",
        paginated = true,
        page_size = 100,
    },
    sync_sources = {
        { endpoint = "/api/v1/opds/libraries", kind = "library" },
        { endpoint = "/api/v1/opds/collections", kind = "collection" },
        { endpoint = "/api/v1/opds/smart-scopes", kind = "smartscope" },
    },
    author_image_path = function(author_id)
        return "/api/v1/authors/" .. tostring(author_id) .. "/image"
    end,
    author_image_token_query = false,
}
