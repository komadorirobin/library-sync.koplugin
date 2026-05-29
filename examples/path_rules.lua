return {
    rules = {
        {
            genre = "Manga",
            series = true,
            path = "Manga/{series}",
            fallback = "Manga/Oneshots",
        },
        {
            genre = "Fiction",
            series = true,
            path = "Fiction/{author_sort} - {series}",
            fallback = "Fiction",
        },
        {
            genre = "Nonfiction",
            path = "Nonfiction",
        },
    },
    fallback = "",
}
