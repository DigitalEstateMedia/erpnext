FROM mariadb:11.8
# Frappe requires utf8mb4 charset; the flags are baked into a config file
# because Railway does not run the image ENTRYPOINT, so we cannot pass them
# as command-line arguments via a start command.
COPY charset.cnf /etc/mysql/conf.d/charset.cnf
