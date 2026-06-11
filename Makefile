PERL ?= perl

.PHONY: default install

default:

install:
	$(PERL) -Ilib -MTelegram::Claude::Manager -e "Telegram::Claude::Manager->new()->auto_setup()"
