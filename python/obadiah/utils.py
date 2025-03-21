# Copyright (C) 2019 Petr Fedorov <petr.fedorov@phystech.edu>

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation,  version 2 of the License

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.


import logging
import logging.handlers
import sys
import traceback
import signal
import psycopg2
import asyncpg


async def connect(dbname, user, application_name):
    con = await asyncpg.connect(user=user, database=dbname)
    await con.execute(f"set application_name to {application_name}")
    return con


def connect_db(dbname, user, application_name):
    return psycopg2.connect("dbname=%s user=%s password=%s "
                            "application_name=%s" %
                            (dbname, user, user, application_name))


def listener_process(logging_queue, log_file_name):
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    root = logging.getLogger()
    h = logging.handlers.RotatingFileHandler(log_file_name,
                                             'a',
                                             2**24,
                                             20)
    f = logging.Formatter('%(asctime)s %(process)-6d %(name)s '
                          '%(levelname)-8s %(message)s')
    h.setFormatter(f)
    root.addHandler(h)
    while True:
        try:
            record = logging_queue.get()
            if record is None:
                break
            logger = logging.getLogger(record.name)
            logger.handle(record)
        except Exception:
            print('Whoops! Problem:', file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
    #  print('Exit - listener_process()', file=sys.stdout)


def logging_configurer(logging_queue, logging_level=logging.DEBUG):
    h = logging.handlers.QueueHandler(logging_queue)
    root = logging.getLogger()
    root.addHandler(h)
    root.setLevel(logging_level)


def log_notices(logger, notices):
    while notices:
        logger.info(notices.pop(0))


class QueueSizeLogger(object):
    def __init__(self, queue, queue_name, threshold=100):
        self.n = 0
        self.queue = queue
        self.queue_name = queue_name
        self.THRE = threshold

    def __call__(self, logger):

        s = self.queue.qsize()
        if (s > self.THRE*2**(self.n)):
            self.n += 1
            logger.warning("Unprocessed %s size: %i" % (self.queue_name, s))
        elif self.n and (s < self.THRE*2**(self.n - 1)):
            self.n -= 1


class Spawned(object):

    def __init__(self, log_queue, stop_flag, log_level=logging.INFO):
        self.log_queue = log_queue
        self.stop_flag = stop_flag
        self.log_level = log_level

    def _call_init(self):
        logging_configurer(self.log_queue, self.log_level)

        signal.signal(signal.SIGINT, signal.SIG_IGN)
