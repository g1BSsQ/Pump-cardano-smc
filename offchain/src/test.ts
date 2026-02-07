import { deserializeAddress } from "@meshsdk/core";

const addr = "addr_test1qp5ze98ws7yvehsmg0kf9fsg6u88u9zd2udzyxzwpvm0ffe0dheqe6zch30uc36lwr2xvnhqmyrl6aqzjfpp4ftxaecsdfm0ty";

console.log(deserializeAddress(addr).pubKeyHash);