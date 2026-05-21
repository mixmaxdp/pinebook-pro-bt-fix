#!/bin/sh
# Pinebook Pro - Attach Bluetooth HCI UART for AP6255 (BCM4345C5)
# Uses hciattach (userspace) instead of kernel serdev/broken hci_uart_bcm driver.

/usr/bin/gpioset gpiochip0 9=0
sleep 1
/usr/bin/gpioset gpiochip0 9=1
/usr/bin/gpioset gpiochip2 27=1
sleep 2

exec /usr/bin/hciattach -s 115200 -n /dev/ttyS0 bcm43xx 460800 flow
