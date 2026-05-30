return {
    rules = {
        -- Grimmory OPDS categories are exposed as genres/tags here.
        {
            tags = { "Manga", "Comics" },
            series = true,
            path = "Comics/{series}",
            fallback = "Comics/Standalone",
        },
        {
            tag = "Nonfiction",
            path = "Nonfiction/{author_sort}",
        },

        -- Author rules match either the OPDS author name or the author-sort name.
        {
            author = "Octavia E. Butler",
            path = "Authors/{author_sort}",
        },
        {
            author = "Butler, Octavia E.",
            path = "Authors/{author_sort}",
        },

        -- Use a function for combined or more specific logic.
        {
            when = function(book, h)
                return h.has_tag(book, "Hugo Award") or h.has_tag(book, "Nebula Award")
            end,
            path = "Award winners/{author_sort}",
        },
    },

    -- Empty fallback means books that match no rule go into the library root.
    fallback = "",
}
