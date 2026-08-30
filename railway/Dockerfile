FROM frappe/erpnext:v16.33.0
USER root
RUN pip install --no-cache-dir supervisor
COPY supervisord.conf /home/frappe/supervisord.conf
COPY start-railway.sh /usr/local/bin/start-railway.sh
RUN chmod 755 /usr/local/bin/start-railway.sh && echo "v3" > /usr/local/bin/start-railway.sh.version
# No USER frappe — Railway mounts volumes as root, so the boot script
# must chown the sites volume as root before switching to frappe.
# The original ENTRYPOINT (main-entrypoint.sh) runs as root and can
# create the assets symlink; start-railway.sh then drops to frappe.
CMD ["start-railway.sh"]
