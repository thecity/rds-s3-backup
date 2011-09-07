What is this?
-------------

This is a simple ruby script to take SQL dumps of RDS instances in an unobtrusive way.

Why would I need it?
--------------------

RDS snapshots are not enough, they are tied to the region and sometimes the availability zone of the server from which they were taken. If an earthquakyphoonicane hits Virginia you won't be able to get to your snapshots. With SQL dumps in S3, however, you are much more likely to be able to bring your server up elsewhere.

This script uses Fog to take a snapshot of your server and start a temporary server based on that snapshot. Then mysqldump is run to get the raw SQL out and put on the disk. Fog then is used to put that SQL file into S3, and clean up the snapshot and the temporary server. 

This approach works great for a multi-AZ primary database server with no replication slaves. If you have replicated slaves you should dump straight from those instead. This script doesn't do that, though it could be easily modified to do so.

How can I use it?
-----------------

You'll need mysqldump, gzip, ruby 1.9.x, and the fog and thor gems on your system. It has a command line interface with like a million options since the script needs so much access to do its job. 

How can I trust it?
-------------------

You probably shouldn't, it's pretty naïve at the moment.