FROM mariadb:11.8
# Frappe requires the utf8mb4 charset; without these three settings `bench
# new-site` fails outright.
#
# They live in a config file rather than a Railway start command on purpose.
# A Railway start command replaces the image CMD (the ENTRYPOINT still runs),
# so passing them as arguments would work — but it would also silently drop
# them the moment anyone edits the start command. Baking them in is
# declarative and survives that.
COPY charset.cnf /etc/mysql/conf.d/charset.cnf
