# DistributedChat
An example of a LocalNetworkActorSystem connecting peer-to-peer on a local network with bonjour, enabling a chat experience

This was originally a demo on Apple's WWDC '22 about distributed actors. I ripped out the tic-tac-toe game and replaced it with a chat UI

This barely makes the connection between two local clients on a network using bonjour. It does connect with multiple devices on the network but the memory balloons very fast.

Next steps would be to integrate the WebSocketNetworkSystem and find a way to connect users over a server connection.
